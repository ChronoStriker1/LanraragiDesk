import Foundation
import LanraragiKit

actor ThumbnailLoader {
    enum ThumbnailError: Error {
        case missingAPIKey
    }

    private let limiter = AsyncLimiter(limit: 4)

    private let cache = NSCache<NSString, NSData>()
    private var inflight: [String: Task<Data, Error>] = [:]
    private var apiKeyByProfileID: [UUID: String] = [:]
    private var clientByProfileID: [UUID: LANraragiClient] = [:]

    init() {
        cache.totalCostLimit = 256 * 1024 * 1024 // ~256MB
    }

    func thumbnailBytes(profile: Profile, arcid: String) async throws -> Data {
        let key = "\(profile.id.uuidString)/\(arcid)" as NSString

        if let data = cache.object(forKey: key) {
            return Data(referencing: data)
        }

        let inflightKey = String(key)
        if let t = inflight[inflightKey] {
            return try await t.value
        }

        let client = try makeClient(profile: profile)
        let task = Task<Data, Error> {
            try await limiter.withPermit {
                return try await client.fetchCoverThumbnailBytes(arcid: arcid)
            }
        }

        inflight[inflightKey] = task
        defer { inflight[inflightKey] = nil }

        let bytes = try await task.value
        cache.setObject(bytes as NSData, forKey: key, cost: bytes.count)
        return bytes
    }

    func invalidate(profile: Profile, arcid: String) {
        let key = "\(profile.id.uuidString)/\(arcid)" as NSString
        cache.removeObject(forKey: key)
        inflight[String(key)]?.cancel()
        inflight[String(key)] = nil
    }

    /// Drops the cached client, API key, and thumbnail cache for a profile.
    /// Call after the profile's base URL or API key changes.
    func invalidateClient(profileID: UUID) {
        apiKeyByProfileID[profileID] = nil
        clientByProfileID[profileID] = nil
        cache.removeAllObjects()
    }

    private func makeClient(profile: Profile) throws -> LANraragiClient {
        if let cached = clientByProfileID[profile.id] {
            return cached
        }

        let apiKeyString: String
        if let cached = apiKeyByProfileID[profile.id] {
            apiKeyString = cached
        } else {
            let account = "apiKey.\(profile.id.uuidString)"
            guard let loaded = try KeychainService.getString(account: account) else {
                throw ThumbnailError.missingAPIKey
            }
            apiKeyString = loaded
            apiKeyByProfileID[profile.id] = loaded
        }

        let client = LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: LANraragiAPIKey(apiKeyString),
            acceptLanguage: profile.language,
            maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
        ))
        clientByProfileID[profile.id] = client
        return client
    }
}
