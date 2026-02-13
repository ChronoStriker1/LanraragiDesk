import Foundation
import LanraragiKit

actor ArchiveLoader {
    enum ArchiveLoaderError: Error {
        case missingAPIKey
    }

    private let limiter = AsyncLimiter(limit: 4)

    private var apiKeyByProfileID: [UUID: String] = [:]

    private var metaCache: [String: ArchiveMetadata] = [:]
    private var metaInflight: [String: Task<ArchiveMetadata, Error>] = [:]

    private var pagesCache: [String: [URL]] = [:]
    private var pagesInflight: [String: Task<[URL], Error>] = [:]

    private let bytesCache = NSCache<NSString, NSData>()
    private var bytesInflight: [String: Task<Data, Error>] = [:]

    init() {
        bytesCache.totalCostLimit = 512 * 1024 * 1024 // ~512MB
    }

    func metadata(profile: Profile, arcid: String) async throws -> ArchiveMetadata {
        if let m = metaCache[arcid] { return m }
        if let t = metaInflight[arcid] { return try await t.value }

        let task = Task<ArchiveMetadata, Error> {
            try await limiter.withPermit {
                let client = try await makeClient(profile: profile)
                return try await client.getArchiveMetadata(arcid: arcid)
            }
        }

        metaInflight[arcid] = task
        defer { metaInflight[arcid] = nil }

        let m = try await task.value
        metaCache[arcid] = m
        return m
    }

    func pageURLs(profile: Profile, arcid: String) async throws -> [URL] {
        if let p = pagesCache[arcid] { return p }
        if let t = pagesInflight[arcid] { return try await t.value }

        let task = Task<[URL], Error> {
            try await limiter.withPermit {
                let client = try await makeClient(profile: profile)
                let resp = try await client.getArchiveFiles(arcid: arcid)
                var out: [URL] = []
                out.reserveCapacity(resp.pages.count)
                for s in resp.pages {
                    out.append(try client.makeAbsoluteURL(from: s))
                }
                return out
            }
        }

        pagesInflight[arcid] = task
        defer { pagesInflight[arcid] = nil }

        let pages = try await task.value
        pagesCache[arcid] = pages
        return pages
    }

    func bytes(profile: Profile, url: URL) async throws -> Data {
        let key = url.absoluteString as NSString
        if let b = bytesCache.object(forKey: key) {
            return Data(referencing: b)
        }

        let inflightKey = String(key)
        if let t = bytesInflight[inflightKey] { return try await t.value }

        let task = Task<Data, Error> {
            try await limiter.withPermit {
                let client = try await makeClient(profile: profile)
                return try await client.fetchBytes(url: url)
            }
        }

        bytesInflight[inflightKey] = task
        defer { bytesInflight[inflightKey] = nil }

        let data = try await task.value
        bytesCache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    private func makeClient(profile: Profile) async throws -> LANraragiClient {
        let apiKeyString: String
        if let cached = apiKeyByProfileID[profile.id] {
            apiKeyString = cached
        } else {
            let account = "apiKey.\(profile.id.uuidString)"
            guard let loaded = try KeychainService.getString(account: account) else {
                throw ArchiveLoaderError.missingAPIKey
            }
            apiKeyString = loaded
            apiKeyByProfileID[profile.id] = loaded
        }

        return LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: LANraragiAPIKey(apiKeyString),
            acceptLanguage: profile.language,
            maxConnectionsPerHost: 8
        ))
    }
}

private actor AsyncLimiter {
    private let limit: Int
    private var active: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func withPermit<T: Sendable>(_ op: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await op()
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }

        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        active += 1
    }

    private func release() {
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
            return
        }
        active -= 1
    }
}

