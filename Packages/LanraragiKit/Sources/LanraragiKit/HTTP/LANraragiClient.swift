import Foundation

public final class LANraragiClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var apiKey: LANraragiAPIKey?
        public var acceptLanguage: String
        public var maxConnectionsPerHost: Int

        public init(
            baseURL: URL,
            apiKey: LANraragiAPIKey? = nil,
            acceptLanguage: String = "en-US",
            maxConnectionsPerHost: Int = 20
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.acceptLanguage = acceptLanguage
            self.maxConnectionsPerHost = maxConnectionsPerHost
        }
    }

    private let config: Configuration
    private let session: URLSession

    public init(configuration: Configuration) {
        self.config = configuration

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpMaximumConnectionsPerHost = configuration.maxConnectionsPerHost
        sessionConfig.waitsForConnectivity = true
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData

        self.session = URLSession(configuration: sessionConfig)
    }

    public func getServerInfo() async throws -> ServerInfo {
        try await getJSON(path: "/api/info")
    }

    public func getArchiveMetadata(arcid: String) async throws -> ArchiveMetadata {
        try await getJSON(path: "/api/archives/\(arcid)/metadata")
    }

    public func getArchiveFiles(arcid: String) async throws -> ArchiveFilesResponse {
        try await getJSON(path: "/api/archives/\(arcid)/files")
    }

    public func fetchBytes(url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyDefaultHeaders(to: &req)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LANraragiError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LANraragiError.invalidResponse
        }
        if http.statusCode == 401 {
            throw LANraragiError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            throw LANraragiError.httpStatus(http.statusCode, body: data)
        }
        return data
    }

    public func makeAbsoluteURL(from possiblyRelative: String) throws -> URL {
        var s = possiblyRelative
        if s.hasPrefix("./") {
            s.removeFirst(2)
        }
        // Some docs/examples show `page&path=...` where `?` should be used.
        if s.contains("/page&path=") {
            s = s.replacingOccurrences(of: "/page&path=", with: "/page?path=")
        }

        if let url = URL(string: s), url.scheme != nil {
            return url
        }

        return try makeURL(path: s.hasPrefix("/") ? s : "/" + s)
    }

    public func search(
        start: Int,
        filter: String = "",
        category: String = "",
        newOnly: Bool = false,
        untaggedOnly: Bool = false,
        sortBy: String = "title",
        order: String = "asc"
    ) async throws -> ArchiveSearch {
        let queryItems: [URLQueryItem] = [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "newonly", value: newOnly ? "true" : "false"),
            URLQueryItem(name: "untaggedonly", value: untaggedOnly ? "true" : "false"),
            URLQueryItem(name: "sortby", value: sortBy),
            URLQueryItem(name: "order", value: order),
        ]
        return try await getJSON(path: "/api/search", queryItems: queryItems)
    }

    public func regenerateThumbnails(force: Bool) async throws -> MinionJob {
        let queryItems = [URLQueryItem(name: "force", value: force ? "1" : "0")]
        return try await postJSON(path: "/api/regen_thumbs", queryItems: queryItems, body: nil)
    }

    public func getMinionStatus(job: Int) async throws -> MinionStatus {
        try await getJSON(path: "/api/minion/\(job)")
    }

    public func getArchiveThumbnail(
        arcid: String,
        noFallback: Bool = true,
        page: Int? = nil
    ) async throws -> ThumbnailResponse {
        var queryItems = [URLQueryItem(name: "no_fallback", value: noFallback ? "true" : "false")]
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }

        let url = try makeURL(path: "/api/archives/\(arcid)/thumbnail", queryItems: queryItems)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyDefaultHeaders(to: &req)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LANraragiError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LANraragiError.invalidResponse
        }

        if http.statusCode == 401 {
            throw LANraragiError.unauthorized
        }

        switch http.statusCode {
        case 200:
            return .bytes(data)
        case 202:
            do {
                return .job(try JSONDecoder().decode(MinionJob.self, from: data))
            } catch {
                throw LANraragiError.decoding(error)
            }
        default:
            throw LANraragiError.httpStatus(http.statusCode, body: data)
        }
    }

    public func fetchCoverThumbnailBytes(
        arcid: String,
        noFallback: Bool = true,
        pollInterval: Duration = .seconds(1),
        maxPolls: Int = 120
    ) async throws -> Data {
        switch try await getArchiveThumbnail(arcid: arcid, noFallback: noFallback, page: nil) {
        case .bytes(let data):
            return data
        case .job(let job):
            var polls = 0
            while polls < maxPolls {
                try Task.checkCancellation()
                try await Task.sleep(for: pollInterval)
                let st = try await getMinionStatus(job: job.job)
                let state = st.state ?? st.data?.state
                if state == nil || state == "finished" {
                    break
                }
                polls += 1
            }

            // Retry after the job completes.
            switch try await getArchiveThumbnail(arcid: arcid, noFallback: noFallback, page: nil) {
            case .bytes(let data):
                return data
            case .job:
                throw LANraragiError.invalidResponse
            }
        }
    }

    private func getJSON<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> T {
        let url = try makeURL(path: path, queryItems: queryItems)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyDefaultHeaders(to: &req)
        return try await perform(req)
    }

    private func postJSON<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data?
    ) async throws -> T {
        let url = try makeURL(path: path, queryItems: queryItems)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyDefaultHeaders(to: &req)
        req.httpBody = body
        return try await perform(req)
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw LANraragiError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LANraragiError.invalidResponse
        }

        if http.statusCode == 401 {
            throw LANraragiError.unauthorized
        }

        guard (200...299).contains(http.statusCode) else {
            throw LANraragiError.httpStatus(http.statusCode, body: data)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LANraragiError.decoding(error)
        }
    }

    private func makeURL(path: String) throws -> URL {
        // Avoid surprising behavior if baseURL includes a trailing slash.
        var base = config.baseURL
        if base.path != "/" && base.path.hasSuffix("/") {
            base.deleteLastPathComponent()
        }

        guard let url = URL(string: path, relativeTo: base) else {
            throw LANraragiError.invalidBaseURL
        }
        return url
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var url = try makeURL(path: path)
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw LANraragiError.invalidBaseURL
        }
        if !queryItems.isEmpty {
            comps.queryItems = queryItems
        }
        guard let out = comps.url else { throw LANraragiError.invalidBaseURL }
        url = out
        return url
    }

    private func applyDefaultHeaders(to req: inout URLRequest) {
        req.setValue("LanraragiDesk", forHTTPHeaderField: "User-Agent")
        req.setValue(config.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        if let key = config.apiKey {
            req.setValue(key.bearerHeaderValue, forHTTPHeaderField: "Authorization")
        }
    }
}
