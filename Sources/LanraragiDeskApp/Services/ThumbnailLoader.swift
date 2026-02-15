import Foundation
import LanraragiKit

actor ThumbnailLoader {
    enum ThumbnailError: Error {
        case missingAPIKey
    }

    private let limiter = AsyncLimiter(limit: 4)

    private let cache = NSCache<NSString, NSData>()
    private var inflight: [String: Task<Data, Error>] = [:]

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

        let account = "apiKey.\(profile.id.uuidString)"
        guard let apiKeyString = try KeychainService.getString(account: account) else {
            throw ThumbnailError.missingAPIKey
        }

        let baseURL = profile.baseURL
        let acceptLanguage = profile.language

        let task = Task<Data, Error> {
            try await limiter.withPermit {
                let client = LANraragiClient(configuration: .init(
                    baseURL: baseURL,
                    apiKey: LANraragiAPIKey(apiKeyString),
                    acceptLanguage: acceptLanguage,
                    maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
                ))
                return try await client.fetchCoverThumbnailBytes(arcid: arcid)
            }
        }

        inflight[inflightKey] = task
        defer { inflight[inflightKey] = nil }

        let bytes = try await task.value
        cache.setObject(bytes as NSData, forKey: key, cost: bytes.count)
        return bytes
    }
}

private actor AsyncLimiter {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        self.available = self.limit
    }

    func withPermit<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await op()
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }

        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        // Permit is transferred directly from `release()` via resuming this continuation.
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
            return
        }
        available = min(limit, available + 1)
    }
}
