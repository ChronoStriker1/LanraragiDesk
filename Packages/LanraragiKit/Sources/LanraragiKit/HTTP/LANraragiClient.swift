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

    public func getArchiveMetadataRaw(arcid: String) async throws -> Data {
        let url = try makeURL(path: "/api/archives/\(arcid)/metadata")
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

    public func getArchiveFiles(arcid: String, force: Bool = false) async throws -> ArchiveFilesResponse {
        let items = force ? [URLQueryItem(name: "force", value: "true")] : []
        return try await getJSON(path: "/api/archives/\(arcid)/files", queryItems: items)
    }

    public func deleteArchive(arcid: String) async throws {
        let url = try makeURL(path: "/api/archives/\(arcid)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
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
    }

    public func updateArchiveMetadata(
        arcid: String,
        title: String,
        tags: String,
        summary: String
    ) async throws {
        let data = makeFormBody([
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "tags", value: tags),
            URLQueryItem(name: "summary", value: summary),
        ])

        let url = try makeURL(path: "/api/archives/\(arcid)/metadata")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyDefaultHeaders(to: &req)
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        try await performNoContent(req)
    }

    public func updateArchiveThumbnail(arcid: String, page: Int? = nil) async throws {
        var queryItems: [URLQueryItem] = []
        if let page {
            queryItems.append(URLQueryItem(name: "page", value: String(max(1, page))))
        }

        let url = try makeURL(path: "/api/archives/\(arcid)/thumbnail", queryItems: queryItems)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyDefaultHeaders(to: &req)

        try await performNoContent(req)
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

    public func getDatabaseStats(minWeight: Int = 0) async throws -> DatabaseStats {
        let queryItems = [URLQueryItem(name: "minweight", value: String(max(0, minWeight)))]
        return try await getJSON(path: "/api/database/stats", queryItems: queryItems)
    }

    public func listCategories() async throws -> [Category] {
        let data = try await getData(path: "/api/categories")
        let obj = try JSONSerialization.jsonObject(with: data)

        // Common shapes:
        // - [{"id":"...", "name":"...", "pinned":true}, ...]
        // - {"categories":[...]}
        // - {"id":"name", ...} (fallback; pinned not representable)
        if let arr = obj as? [Any] {
            return parseCategoriesArray(arr)
        }
        if let dict = obj as? [String: Any] {
            if let arr = dict["categories"] as? [Any] {
                return parseCategoriesArray(arr)
            }
            // Fallback: mapping of id -> name
            var out: [Category] = []
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                if let name = v as? String {
                    out.append(Category(id: k, name: name, pinned: false))
                }
            }
            return out
        }

        return []
    }

    public func listPlugins(type: String = "metadata") async throws -> [PluginInfo] {
        let obj: Any
        do {
            let data = try await getData(path: "/api/plugins/\(type)")
            obj = try JSONSerialization.jsonObject(with: data)
        } catch let error as LANraragiError {
            // Backward-compat fallback if a server exposes /api/plugins without a type segment.
            switch error {
            case .httpStatus(let code, _) where code == 404:
                let data = try await getData(path: "/api/plugins")
                obj = try JSONSerialization.jsonObject(with: data)
            default:
                throw error
            }
        }

        // Common shapes:
        // - ["pluginA", "pluginB"]
        // - [{"id":"...", "name":"...", "desc":"..."}]
        // - {"plugins":[...]}
        if let arr = obj as? [Any] {
            return parsePluginsArray(arr)
        }
        if let dict = obj as? [String: Any] {
            if let arr = dict["plugins"] as? [Any] {
                return parsePluginsArray(arr)
            }
        }

        return []
    }

    private func parseCategoriesArray(_ arr: [Any]) -> [Category] {
        var out: [Category] = []
        out.reserveCapacity(arr.count)

        for item in arr {
            if let dict = item as? [String: Any] {
                let id = (dict["id"] as? String) ?? ""
                let name = (dict["name"] as? String) ?? ""
                let pinned: Bool = {
                    if let b = dict["pinned"] as? Bool { return b }
                    if let i = dict["pinned"] as? Int { return i != 0 }
                    if let s = dict["pinned"] as? String {
                        switch s.lowercased() {
                        case "true", "1", "yes": return true
                        default: return false
                        }
                    }
                    return false
                }()

                out.append(Category(id: id, name: name, pinned: pinned))
                continue
            }

            // Some servers might return category names as plain strings.
            if let name = item as? String {
                out.append(Category(id: name, name: name, pinned: false))
            }
        }

        return out
    }

    public func queuePlugin(pluginID: String, arcid: String, arg: String? = nil) async throws -> MinionJob {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "plugin", value: pluginID),
            URLQueryItem(name: "id", value: arcid),
        ]
        if let arg, !arg.isEmpty {
            items.append(URLQueryItem(name: "arg", value: arg))
        }
        let formBody = makeFormBody(items)

        do {
            let data = try await postData(
                path: "/api/plugins/queue",
                body: formBody,
                contentType: "application/x-www-form-urlencoded; charset=utf-8"
            )
            return try parseQueuedPluginJob(from: data)
        } catch let lrrError as LANraragiError {
            // Some servers only expose GET on this endpoint; retain a compatibility fallback.
            switch lrrError {
            case .httpStatus(let code, _) where code == 404 || code == 405:
                let data = try await getData(path: "/api/plugins/queue", queryItems: items)
                return try parseQueuedPluginJob(from: data)
            default:
                throw lrrError
            }
        }
    }

    public func runPlugin(pluginID: String, arcid: String, arg: String? = nil) async throws -> String {
        var formItems: [URLQueryItem] = [
            URLQueryItem(name: "plugin", value: pluginID),
            URLQueryItem(name: "id", value: arcid),
        ]
        if let arg, !arg.isEmpty {
            formItems.append(URLQueryItem(name: "arg", value: arg))
        }
        let data = try await postData(
            path: "/api/plugins/use",
            body: makeFormBody(formItems),
            contentType: "application/x-www-form-urlencoded; charset=utf-8"
        )
        return String(decoding: data, as: UTF8.self)
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

    private func getData(path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        let url = try makeURL(path: path, queryItems: queryItems)
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

    private func postData(
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data?,
        contentType: String? = nil
    ) async throws -> Data {
        let url = try makeURL(path: path, queryItems: queryItems)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyDefaultHeaders(to: &req)
        if let contentType {
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        req.httpBody = body

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

    private func performNoContent(_ req: URLRequest) async throws {
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

    private func parsePluginsArray(_ arr: [Any]) -> [PluginInfo] {
        var out: [PluginInfo] = []
        out.reserveCapacity(arr.count)

        for item in arr {
            if let s = item as? String {
                out.append(.init(id: s, title: s))
            } else if let d = item as? [String: Any] {
                let id = (d["id"] as? String)
                    ?? (d["namespace"] as? String)
                    ?? (d["plugin"] as? String)
                    ?? (d["name"] as? String)
                    ?? ""
                let title = (d["title"] as? String) ?? (d["name"] as? String) ?? id
                let desc = (d["desc"] as? String) ?? (d["description"] as? String)
                let oneshotArg = (d["oneshot_arg"] as? String) ?? (d["oneshotArg"] as? String)
                let parameters = parsePluginParameters(d["parameters"])
                if !id.isEmpty || !title.isEmpty {
                    out.append(.init(
                        id: id.isEmpty ? title : id,
                        title: title.isEmpty ? id : title,
                        description: desc,
                        oneshotArg: oneshotArg,
                        parameters: parameters
                    ))
                }
            }
        }

        out.sort { a, b in a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
        return out
    }

    private func parsePluginParameters(_ raw: Any?) -> [PluginInfo.Parameter] {
        if let arr = raw as? [Any] {
            return arr.enumerated().compactMap { idx, item in
                if let dict = item as? [String: Any] {
                    let name = stringValue(dict["name"])
                    let id = (name?.isEmpty == false ? name! : "param_\(idx)")
                    let defaultValue: String?
                    if let v = stringValue(dict["default_value"]) {
                        defaultValue = v
                    } else {
                        defaultValue = stringValue(dict["default"])
                    }
                    return .init(
                        id: id,
                        name: name,
                        type: stringValue(dict["type"]),
                        description: stringValue(dict["desc"]) ?? stringValue(dict["description"]),
                        value: stringValue(dict["value"]),
                        defaultValue: defaultValue
                    )
                }

                if let text = stringValue(item), !text.isEmpty {
                    return .init(id: "param_\(idx)", description: text)
                }
                return nil
            }
        }

        // Some servers can still return a hash keyed by parameter names.
        if let dict = raw as? [String: Any] {
            return dict.keys.sorted().enumerated().compactMap { idx, key in
                if let valueDict = dict[key] as? [String: Any] {
                    let defaultValue: String?
                    if let v = stringValue(valueDict["default_value"]) {
                        defaultValue = v
                    } else {
                        defaultValue = stringValue(valueDict["default"])
                    }
                    return .init(
                        id: key.isEmpty ? "param_\(idx)" : key,
                        name: key,
                        type: stringValue(valueDict["type"]),
                        description: stringValue(valueDict["desc"]) ?? stringValue(valueDict["description"]),
                        value: stringValue(valueDict["value"]),
                        defaultValue: defaultValue
                    )
                }

                return .init(
                    id: key.isEmpty ? "param_\(idx)" : key,
                    name: key,
                    value: stringValue(dict[key])
                )
            }
        }

        return []
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let n = value as? NSNumber { return n.stringValue }
        if let arr = value as? [Any] {
            let parts = arr.compactMap { stringValue($0) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if let dict = value as? [String: Any],
           JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: value)
    }

    private func parseQueuedPluginJob(from data: Data) throws -> MinionJob {
        if let job = try? JSONDecoder().decode(MinionJob.self, from: data), job.job > 0 {
            return job
        }

        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LANraragiError.decoding(error)
        }

        if let jobID = findQueuedPluginJobID(in: obj) {
            return MinionJob(job: jobID)
        }
        let err = NSError(
            domain: "LANraragiClient",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to parse plugin queue job id from response."]
        )
        throw LANraragiError.decoding(err)
    }

    private func findQueuedPluginJobID(in value: Any) -> Int? {
        if let int = value as? Int {
            return int > 0 ? int : nil
        }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return nil
            }
            let id = num.intValue
            return id > 0 ? id : nil
        }
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if let exact = Int(trimmed), exact > 0 {
                return exact
            }
            let pattern = #"(?i)\bjob(?:_id|id)?\D+(\d+)\b"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: trimmed),
               let parsed = Int(trimmed[range]),
               parsed > 0 {
                return parsed
            }
            return nil
        }
        if let dict = value as? [String: Any] {
            let preferredKeys = ["job", "job_id", "jobId", "id"]
            for key in preferredKeys {
                if let found = dict[key], let parsed = findQueuedPluginJobID(in: found) {
                    return parsed
                }
            }
            for nested in dict.values where nested is [Any] || nested is [String: Any] {
                if let parsed = findQueuedPluginJobID(in: nested) {
                    return parsed
                }
            }
            return nil
        }
        if let arr = value as? [Any] {
            for item in arr {
                if let parsed = findQueuedPluginJobID(in: item) {
                    return parsed
                }
            }
            return nil
        }
        return nil
    }

    private func makeFormBody(_ items: [URLQueryItem]) -> Data {
        var comps = URLComponents()
        comps.queryItems = items
        let encoded = comps.percentEncodedQuery ?? ""
        return Data(encoded.utf8)
    }
}
