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
        let url = try makeURL(path: "/api/info")
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

        do {
            return try JSONDecoder().decode(ServerInfo.self, from: data)
        } catch {
            throw LANraragiError.decoding(error)
        }
    }

    private func makeURL(path: String) throws -> URL {
        // Ensure baseURL ends without trailing slash to avoid double slashes.
        var base = config.baseURL
        if base.path.hasSuffix("/") {
            base.deleteLastPathComponent()
        }

        guard let url = URL(string: path, relativeTo: base) else {
            throw LANraragiError.invalidBaseURL
        }
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
