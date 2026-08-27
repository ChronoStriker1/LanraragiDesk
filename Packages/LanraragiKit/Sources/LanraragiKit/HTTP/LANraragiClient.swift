import Foundation

public final class LANraragiClient: Sendable {
    enum ThumbnailJobPollDecision: Equatable {
        case completed
        case failed(state: String)
        case pending(state: String)
    }

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
        order: String = "asc",
        groupByTanks: Bool = true,
        hideCompleted: Bool = false
    ) async throws -> ArchiveSearch {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "sortby", value: sortBy),
            URLQueryItem(name: "order", value: order),
        ]
        // Servers with strict OpenAPI validation reject empty values (e.g. category
        // has a minimum length), so only send params that carry a real value.
        if !filter.isEmpty {
            queryItems.append(URLQueryItem(name: "filter", value: filter))
        }
        if !category.isEmpty {
            queryItems.append(URLQueryItem(name: "category", value: category))
        }
        if newOnly {
            queryItems.append(URLQueryItem(name: "newonly", value: "true"))
        }
        if untaggedOnly {
            queryItems.append(URLQueryItem(name: "untaggedonly", value: "true"))
        }
        // Only send non-default values so older servers never see unknown params.
        if !groupByTanks {
            queryItems.append(URLQueryItem(name: "groupby_tanks", value: "false"))
        }
        if hideCompleted {
            queryItems.append(URLQueryItem(name: "hidecompleted", value: "true"))
        }
        return try await getJSON(path: "/api/search", queryItems: queryItems)
    }

    public func randomSearch(
        filter: String = "",
        category: String = "",
        count: Int = 5,
        newOnly: Bool = false,
        untaggedOnly: Bool = false,
        groupByTanks: Bool = true
    ) async throws -> RandomArchiveSearch {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "count", value: String(max(1, count))),
        ]
        // Same as search(): omit empty/default params to satisfy strict validators.
        if !filter.isEmpty {
            queryItems.append(URLQueryItem(name: "filter", value: filter))
        }
        if !category.isEmpty {
            queryItems.append(URLQueryItem(name: "category", value: category))
        }
        if newOnly {
            queryItems.append(URLQueryItem(name: "newonly", value: "true"))
        }
        if untaggedOnly {
            queryItems.append(URLQueryItem(name: "untaggedonly", value: "true"))
        }
        if !groupByTanks {
            queryItems.append(URLQueryItem(name: "groupby_tanks", value: "false"))
        }
        return try await getJSON(path: "/api/search/random", queryItems: queryItems)
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
        return try Self.decodeCategoriesResponse(from: data)
    }

    static func decodeCategoriesResponse(from data: Data) throws -> [Category] {
        let obj = try decodeJSONObject(from: data)

        // Common shapes:
        // - [{"id":"...", "name":"...", "pinned":true}, ...]
        // - {"categories":[...]}
        // - {"id":"name", ...} (fallback; pinned not representable)
        if let arr = obj as? [Any] {
            return parseCategoriesArray(arr)
        }
        if let dict = obj as? [String: Any] {
            if let categories = dict["categories"] {
                guard let arr = categories as? [Any] else {
                    throw decodingFailure("Expected categories to be an array.")
                }
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

        throw decodingFailure("Expected a category array or object.")
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

    private static func parseCategoriesArray(_ arr: [Any]) -> [Category] {
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

    // MARK: - Tankoubons

    public func listTankoubons(page: Int? = nil) async throws -> TankoubonList {
        var items: [URLQueryItem] = []
        if let page {
            items.append(URLQueryItem(name: "page", value: String(page)))
        }
        return try await getJSON(path: "/api/tankoubons", queryItems: items)
    }

    /// Creates a Tankoubon, or renames an existing one when `tankID` is provided.
    /// Returns the created/updated Tankoubon ID.
    @discardableResult
    public func createTankoubon(name: String, tankID: String? = nil) async throws -> String {
        var items = [URLQueryItem(name: "name", value: name)]
        if let tankID, !tankID.isEmpty {
            items.append(URLQueryItem(name: "tankid", value: tankID))
        }

        let url = try makeURL(path: "/api/tankoubons")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyDefaultHeaders(to: &req)
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = makeFormBody(items)

        let data = try await performData(req)
        let obj = try Self.decodeJSONObjectDictionary(from: data)
        guard let id = obj["tankoubon_id"] as? String, !id.isEmpty else {
            let err = NSError(
                domain: "LANraragiClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to parse tankoubon_id from response."]
            )
            throw LANraragiError.decoding(err)
        }
        return id
    }

    public func getTankoubon(id: String) async throws -> Tankoubon {
        try await getJSON(path: "/api/tankoubons/\(id)")
    }

    /// `page` of -1 returns all archives with full metadata.
    public func getTankoubonFull(id: String, page: Int = -1) async throws -> TankoubonFullResponse {
        let items = [URLQueryItem(name: "page", value: String(page))]
        return try await getJSON(path: "/api/tankoubons/\(id)/full", queryItems: items)
    }

    /// Updates a Tankoubon's contents and/or metadata.
    /// Pass only the pieces you want changed: `archives` replaces the ordered contents,
    /// metadata fields replace their current values (tags append when `appendTags` is true).
    public func updateTankoubon(
        id: String,
        archives: [String]? = nil,
        name: String? = nil,
        summary: String? = nil,
        tags: String? = nil,
        appendTags: Bool = false
    ) async throws {
        var body: [String: Any] = [:]
        if let archives {
            body["archives"] = archives
        }
        var metadata: [String: Any] = [:]
        if let name { metadata["name"] = name }
        if let summary { metadata["summary"] = summary }
        if let tags {
            metadata["tags"] = tags
            if appendTags { metadata["append"] = true }
        }
        if !metadata.isEmpty {
            body["metadata"] = metadata
        }

        let url = try makeURL(path: "/api/tankoubons/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyDefaultHeaders(to: &req)
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await performNoContent(req)
    }

    public func deleteTankoubon(id: String) async throws {
        let url = try makeURL(path: "/api/tankoubons/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyDefaultHeaders(to: &req)
        try await performNoContent(req)
    }

    /// Appends an archive at the final position of a Tankoubon.
    public func addArchiveToTankoubon(tankID: String, arcid: String) async throws {
        let url = try makeURL(path: "/api/tankoubons/\(tankID)/\(arcid)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyDefaultHeaders(to: &req)
        try await performNoContent(req)
    }

    public func removeArchiveFromTankoubon(tankID: String, arcid: String) async throws {
        let url = try makeURL(path: "/api/tankoubons/\(tankID)/\(arcid)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyDefaultHeaders(to: &req)
        try await performNoContent(req)
    }

    /// Sets the tank cover from a global 1-indexed page number spanning all archives in order.
    public func updateTankoubonThumbnail(tankID: String, page: Int) async throws {
        let items = [URLQueryItem(name: "page", value: String(max(1, page)))]
        let url = try makeURL(path: "/api/tankoubons/\(tankID)/thumbnail", queryItems: items)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyDefaultHeaders(to: &req)
        try await performNoContent(req)
    }

    /// Updates server-side reading progress. `page` is global across all archives in the tank.
    public func updateTankoubonProgress(tankID: String, page: Int) async throws {
        let url = try makeURL(path: "/api/tankoubons/\(tankID)/progress/\(max(1, page))")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyDefaultHeaders(to: &req)
        try await performNoContent(req)
    }

    /// Returns the IDs of all Tankoubons containing the given archive.
    public func getArchiveTankoubons(arcid: String) async throws -> [String] {
        let data = try await getData(path: "/api/archives/\(arcid)/tankoubons")
        return try Self.decodeArchiveTankoubonsResponse(from: data)
    }

    static func decodeArchiveTankoubonsResponse(from data: Data) throws -> [String] {
        let obj = try decodeJSONObjectDictionary(from: data)
        guard let tankoubons = obj["tankoubons"] as? [String] else {
            throw decodingFailure("Expected tankoubons to be an array of IDs.")
        }
        return tankoubons
    }

    // MARK: - Stamps

    /// Returns the 1-indexed page numbers that have at least one stamp.
    public func getStampedPages(arcid: String) async throws -> [Int] {
        let data = try await getData(path: "/api/archives/\(arcid)/stamps")
        return try Self.decodeStampedPagesResponse(from: data)
    }

    static func decodeStampedPagesResponse(from data: Data) throws -> [Int] {
        let obj = try decodeJSONObjectDictionary(from: data)
        guard let arr = obj["result"] as? [Any] else {
            throw decodingFailure("Expected stamp result to be an array of page numbers.")
        }
        var pages: [Int] = []
        pages.reserveCapacity(arr.count)
        for item in arr {
            if let i = item as? Int {
                pages.append(i)
                continue
            }
            if let n = item as? NSNumber {
                pages.append(n.intValue)
                continue
            }
            if let s = item as? String, let page = Int(s) {
                pages.append(page)
                continue
            }
            throw decodingFailure("Stamp result contained a non-numeric page value.")
        }
        return pages.sorted()
    }

    public func getStamps(arcid: String, page: Int) async throws -> [Stamp] {
        struct Wrapper: Decodable {
            var result: [Stamp]?
        }
        let data = try await getData(path: "/api/archives/\(arcid)/stamps/\(page)")
        do {
            let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
            return wrapper.result ?? []
        } catch {
            throw LANraragiError.decoding(error)
        }
    }

    /// Adds a stamp to a page. `position` is `"x,y"` normalized 0–100. Returns the new stamp ID.
    @discardableResult
    public func addStamp(arcid: String, page: Int, content: String, position: String) async throws -> String {
        let items = [
            URLQueryItem(name: "content", value: content),
            URLQueryItem(name: "position", value: position),
        ]
        let url = try makeURL(path: "/api/archives/\(arcid)/stamps/\(page)", queryItems: items)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyDefaultHeaders(to: &req)

        let data = try await performData(req)
        return try Self.decodeAddedStampResponse(from: data)
    }

    static func decodeAddedStampResponse(from data: Data) throws -> String {
        let obj = try decodeJSONObjectDictionary(from: data)
        guard let stampID = obj["stamp_id"] as? String, !stampID.isEmpty else {
            throw decodingFailure("Expected a non-empty stamp_id.")
        }
        return stampID
    }

    public func getStamp(id: String) async throws -> Stamp {
        struct Wrapper: Decodable {
            var result: Stamp
        }
        let data = try await getData(path: "/api/stamps/\(id)")
        do {
            return try JSONDecoder().decode(Wrapper.self, from: data).result
        } catch {
            throw LANraragiError.decoding(error)
        }
    }

    public func updateStamp(id: String, content: String? = nil, position: String? = nil) async throws {
        var items: [URLQueryItem] = []
        if let content {
            items.append(URLQueryItem(name: "content", value: content))
        }
        if let position {
            items.append(URLQueryItem(name: "position", value: position))
        }
        let url = try makeURL(path: "/api/stamps/\(id)", queryItems: items)
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyDefaultHeaders(to: &req)
        try await performNoContent(req)
    }

    public func deleteStamp(id: String) async throws {
        let url = try makeURL(path: "/api/stamps/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyDefaultHeaders(to: &req)
        try await performNoContent(req)
    }

    public func getArchiveThumbnail(
        arcid: String,
        noFallback: Bool = true,
        page: Int? = nil
    ) async throws -> ThumbnailResponse {
        var queryItems = [URLQueryItem(name: "no_fallback", value: noFallback ? "true" : "false")]
        // Tankoubon thumbnails live under a different route and take no page param.
        let path: String
        if LANraragiID.isTankoubon(arcid) {
            path = "/api/tankoubons/\(arcid)/thumbnail"
        } else {
            path = "/api/archives/\(arcid)/thumbnail"
            if let page {
                queryItems.append(URLQueryItem(name: "page", value: String(page)))
            }
        }

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
            return try await Self.waitForThumbnailJob(
                jobID: job.job,
                pollInterval: pollInterval,
                maxPolls: maxPolls,
                status: { [self] in
                    let st = try await getMinionStatus(job: job.job)
                    return st.state ?? st.data?.state
                },
                fetchThumbnail: { [self] in
                    try await getArchiveThumbnail(arcid: arcid, noFallback: noFallback, page: nil)
                }
            )
        }
    }

    static func waitForThumbnailJob(
        jobID: Int,
        pollInterval: Duration,
        maxPolls: Int,
        status: @Sendable () async throws -> String?,
        fetchThumbnail: @Sendable () async throws -> ThumbnailResponse
    ) async throws -> Data {
        let pollLimit = max(0, maxPolls)
        for _ in 0..<pollLimit {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
            switch thumbnailJobPollDecision(state: try await status()) {
            case .completed:
                // Retry only after the job reports completion.
                switch try await fetchThumbnail() {
                case .bytes(let data):
                    return data
                case .job:
                    throw LANraragiError.invalidResponse
                }
            case .failed(let state):
                let message = "Thumbnail generation job \(jobID) failed (state: \(state))."
                throw LANraragiError.httpStatus(500, body: Data(message.utf8))
            case .pending:
                continue
            }
        }

        // A nonterminal job may still be running. Fetching again here is premature and
        // can queue or return another job, so report the polling timeout directly.
        let message = "Thumbnail generation job \(jobID) did not finish after \(pollLimit) polls."
        throw LANraragiError.httpStatus(504, body: Data(message.utf8))
    }

    static func thumbnailJobPollDecision(state: String?) -> ThumbnailJobPollDecision {
        guard let state else {
            // Some LANraragi variants omit state once a job is complete.
            return .completed
        }

        let normalizedState = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedState {
        case "finished":
            return .completed
        case "failed":
            return .failed(state: normalizedState)
        default:
            return .pending(state: normalizedState)
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

    private func performData(_ req: URLRequest) async throws -> Data {
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

    private static func decodeJSONObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LANraragiError.decoding(error)
        }
    }

    private static func decodeJSONObjectDictionary(from data: Data) throws -> [String: Any] {
        let object = try decodeJSONObject(from: data)
        guard let dictionary = object as? [String: Any] else {
            throw decodingFailure("Expected a JSON object response.")
        }
        return dictionary
    }

    private static func decodingFailure(_ message: String) -> LANraragiError {
        let error = NSError(
            domain: "LANraragiClient",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        return .decoding(error)
    }

    func makeURL(path: String) throws -> URL {
        guard
            var baseComponents = URLComponents(
                url: config.baseURL,
                resolvingAgainstBaseURL: false
            ),
            let pathComponents = URLComponents(string: path)
        else {
            throw LANraragiError.invalidBaseURL
        }

        var basePath = baseComponents.percentEncodedPath
        while basePath.count > 1 && basePath.hasSuffix("/") {
            basePath.removeLast()
        }

        let pathSuffix = String(pathComponents.percentEncodedPath.drop(while: { $0 == "/" }))
        if basePath.isEmpty || basePath == "/" {
            baseComponents.percentEncodedPath = "/" + pathSuffix
        } else if pathSuffix.isEmpty {
            baseComponents.percentEncodedPath = basePath + "/"
        } else {
            baseComponents.percentEncodedPath = basePath + "/" + pathSuffix
        }
        baseComponents.percentEncodedQuery = pathComponents.percentEncodedQuery
        baseComponents.percentEncodedFragment = pathComponents.percentEncodedFragment

        guard let url = baseComponents.url else {
            throw LANraragiError.invalidBaseURL
        }
        return url
    }

    func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var url = try makeURL(path: path)
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw LANraragiError.invalidBaseURL
        }
        if !queryItems.isEmpty {
            comps.queryItems = queryItems
            comps.percentEncodedQuery = comps.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let out = comps.url else { throw LANraragiError.invalidBaseURL }
        url = out
        return url
    }

    func applyDefaultHeaders(to req: inout URLRequest) {
        req.setValue("LanraragiDesk", forHTTPHeaderField: "User-Agent")
        req.setValue(config.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        // Archive page URLs may be absolute and cross-origin. Never forward the
        // server credential to a destination that the configured profile does
        // not authenticate.
        if let key = config.apiKey, hasSameOrigin(req.url, as: config.baseURL) {
            req.setValue(key.bearerHeaderValue, forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(nil, forHTTPHeaderField: "Authorization")
        }
    }

    private func hasSameOrigin(_ requestURL: URL?, as baseURL: URL) -> Bool {
        guard
            let requestURL,
            let requestScheme = requestURL.scheme?.lowercased(),
            let baseScheme = baseURL.scheme?.lowercased(),
            let requestHost = requestURL.host?.lowercased(),
            let baseHost = baseURL.host?.lowercased(),
            requestScheme == baseScheme,
            requestHost == baseHost
        else {
            return false
        }

        return effectivePort(for: requestURL, scheme: requestScheme)
            == effectivePort(for: baseURL, scheme: baseScheme)
    }

    private func effectivePort(for url: URL, scheme: String) -> Int? {
        if let port = url.port {
            return port
        }
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
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

    func makeFormBody(_ items: [URLQueryItem]) -> Data {
        var comps = URLComponents()
        comps.queryItems = items
        let encoded = comps.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B") ?? ""
        return Data(encoded.utf8)
    }
}
