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

    private var metaRawCache: [String: String] = [:]
    private var metaRawInflight: [String: Task<String, Error>] = [:]

    private var pagesCache: [String: [URL]] = [:]
    private var pagesInflight: [String: Task<[URL], Error>] = [:]

    private let bytesCache = NSCache<NSString, NSData>()
    private var bytesInflight: [String: Task<Data, Error>] = [:]

    private let maxCachedBytes = 8 * 1024 * 1024

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

    func updateMetadata(
        profile: Profile,
        arcid: String,
        title: String,
        tags: String,
        summary: String
    ) async throws -> ArchiveMetadata {
        let client = try await makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.updateArchiveMetadata(arcid: arcid, title: title, tags: tags, summary: summary)
        }

        // Refresh caches for this archive.
        metaCache[arcid] = nil
        metaRawCache[arcid] = nil

        let updated = try await metadata(profile: profile, arcid: arcid)
        return updated
    }

    func updateThumbnail(
        profile: Profile,
        arcid: String,
        page: Int? = nil
    ) async throws {
        let client = try await makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.updateArchiveThumbnail(arcid: arcid, page: page)
        }
    }

    func deleteArchive(profile: Profile, arcid: String) async throws {
        let client = try await makeClient(profile: profile)
        do {
            try await limiter.withPermit {
                try await client.deleteArchive(arcid: arcid)
            }
        } catch let LANraragiError.httpStatus(code, _) where code == 404 || code == 410 {
            // Treat delete as idempotent if the archive is already gone server-side.
        }

        // Drop cached references for the deleted archive.
        metaCache[arcid] = nil
        metaRawCache[arcid] = nil
        pagesCache[arcid] = nil
        metaInflight[arcid]?.cancel()
        metaRawInflight[arcid]?.cancel()
        pagesInflight[arcid]?.cancel()
        metaInflight[arcid] = nil
        metaRawInflight[arcid] = nil
        pagesInflight[arcid] = nil
    }

    func metadataPrettyJSON(profile: Profile, arcid: String) async throws -> String {
        if let s = metaRawCache[arcid] { return s }
        if let t = metaRawInflight[arcid] { return try await t.value }

        let task = Task<String, Error> {
            try await limiter.withPermit {
                let client = try await makeClient(profile: profile)
                let data = try await client.getArchiveMetadataRaw(arcid: arcid)

                guard
                    let obj = try? JSONSerialization.jsonObject(with: data),
                    let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                    let str = String(data: pretty, encoding: .utf8)
                else {
                    return String(decoding: data, as: UTF8.self)
                }

                return str
            }
        }

        metaRawInflight[arcid] = task
        defer { metaRawInflight[arcid] = nil }

        let s = try await task.value
        metaRawCache[arcid] = s
        return s
    }

    func pageURLs(profile: Profile, arcid: String) async throws -> [URL] {
        if let p = pagesCache[arcid], p.count > 1 { return p }
        if let t = pagesInflight[arcid] { return try await t.value }

        let task = Task<[URL], Error> {
            try await limiter.withPermit {
                let client = try await makeClient(profile: profile)
                let resp: ArchiveFilesResponse
                do {
                    let initial = try await client.getArchiveFiles(arcid: arcid, force: false)
                    if initial.pages.count <= 1 {
                        // Some servers return only the first extracted page unless forced.
                        let forced = try await client.getArchiveFiles(arcid: arcid, force: true)
                        resp = forced.pages.count > initial.pages.count ? forced : initial
                    } else {
                        resp = initial
                    }
                } catch let LANraragiError.httpStatus(code, _) where code == 400 {
                    // Some LANraragi setups return 400 unless file listing is forced (e.g. stale extraction state).
                    resp = try await client.getArchiveFiles(arcid: arcid, force: true)
                }
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
        if data.count <= maxCachedBytes {
            bytesCache.setObject(data as NSData, forKey: key, cost: data.count)
        }
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
            maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
        ))
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
