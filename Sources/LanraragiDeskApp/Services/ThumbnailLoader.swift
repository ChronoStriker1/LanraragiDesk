import Foundation
import LanraragiKit

struct ThumbnailLoaderFetchOverride: Sendable {
    let bytes: @Sendable (Profile, String) async throws -> Data
}

actor ThumbnailLoader {
    enum ThumbnailError: Error {
        case missingAPIKey
    }

    private let limiter = AsyncLimiter(limit: 4)

    private let cache = NSCache<NSString, NSData>()
    private var cacheKeysByProfileID: [UUID: Set<String>] = [:]
    private var inflight = ArchiveLoaderInFlightRegistry<ThumbnailKey, Data>()
    private var apiKeyByProfileID: [UUID: String] = [:]
    private var clientByProfileID: [UUID: LANraragiClient] = [:]
    private var clientGenerationByProfileID: [UUID: UInt64] = [:]
    private let fetchOverride: ThumbnailLoaderFetchOverride?

    init(fetchOverride: ThumbnailLoaderFetchOverride? = nil) {
        self.fetchOverride = fetchOverride
        cache.totalCostLimit = 256 * 1024 * 1024 // ~256MB
    }

    func thumbnailBytes(profile: Profile, arcid: String) async throws -> Data {
        let key = ThumbnailKey(profileID: profile.id, arcid: arcid)
        let cacheKeyString = key.cacheKey
        let cacheKey = cacheKeyString as NSString
        let generation = clientGeneration(for: profile.id)

        if let data = cache.object(forKey: cacheKey) {
            return Data(referencing: data)
        }

        if let operation = inflight[key], operation.generation == generation {
            return try await operation.task.value
        }

        let fetchBytes: @Sendable () async throws -> Data
        if let fetchOverride {
            fetchBytes = {
                try await fetchOverride.bytes(profile, arcid)
            }
        } else {
            let client = try makeClient(profile: profile)
            fetchBytes = {
                try await client.fetchCoverThumbnailBytes(arcid: arcid)
            }
        }
        let task = Task<Data, Error> {
            try await limiter.withPermit {
                try await fetchBytes()
            }
        }

        let operation = inflight.insert(task, for: key, generation: generation)

        do {
            let bytes = try await task.value
            if clientGeneration(for: profile.id) == generation,
               inflight.removeValue(
                   for: key,
                   ownedBy: operation.id,
                   generation: generation
               ) {
                cache.setObject(bytes as NSData, forKey: cacheKey, cost: bytes.count)
                cacheKeysByProfileID[profile.id, default: []].insert(cacheKeyString)
            }
            return bytes
        } catch {
            if clientGeneration(for: profile.id) == generation {
                inflight.removeValue(
                    for: key,
                    ownedBy: operation.id,
                    generation: generation
                )
            }
            throw error
        }
    }

    func invalidate(profile: Profile, arcid: String) {
        let key = ThumbnailKey(profileID: profile.id, arcid: arcid)
        cache.removeObject(forKey: key.cacheKey as NSString)
        cacheKeysByProfileID[profile.id]?.remove(key.cacheKey)
        inflight.cancelAndRemoveValue(for: key)
    }

    /// Drops the cached client, API key, and thumbnail cache for a profile.
    /// Call after the profile's base URL or API key changes.
    func invalidateClient(profileID: UUID) {
        clientGenerationByProfileID[profileID] = clientGeneration(for: profileID) &+ 1
        apiKeyByProfileID[profileID] = nil
        clientByProfileID[profileID] = nil
        for key in cacheKeysByProfileID.removeValue(forKey: profileID) ?? [] {
            cache.removeObject(forKey: key as NSString)
        }
        inflight.cancelAndRemoveAll { $0.profileID == profileID }
    }

    private func clientGeneration(for profileID: UUID) -> UInt64 {
        clientGenerationByProfileID[profileID, default: 0]
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

private struct ThumbnailKey: Hashable, Sendable {
    let profileID: UUID
    let arcid: String

    var cacheKey: String {
        "\(profileID.uuidString)/\(arcid)"
    }
}
