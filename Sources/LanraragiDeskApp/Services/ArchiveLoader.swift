import Foundation
import LanraragiKit

actor ArchiveLoader {
    enum ArchiveLoaderError: Error {
        case missingAPIKey
    }

    private let limiter = AsyncLimiter(limit: 4)

    private var apiKeyByProfileID: [UUID: String] = [:]
    private var clientByProfileID: [UUID: LANraragiClient] = [:]

    private var metaCache: [String: ArchiveMetadata] = [:]
    private var metaInflight: [String: Task<ArchiveMetadata, Error>] = [:]

    private var pagesCache: [String: [URL]] = [:]
    private var pagesInflight: [String: Task<[URL], Error>] = [:]

    private let bytesCache = NSCache<NSString, NSData>()
    private var bytesInflight: [String: Task<Data, Error>] = [:]

    private let maxCachedBytes = 8 * 1024 * 1024

    init() {
        bytesCache.totalCostLimit = 512 * 1024 * 1024 // ~512MB
    }

    func metadata(profile: Profile, arcid: String, forceRefresh: Bool = false) async throws -> ArchiveMetadata {
        if forceRefresh {
            metaCache[arcid] = nil
            metaInflight[arcid]?.cancel()
            metaInflight[arcid] = nil
        }
        if let m = metaCache[arcid] { return m }
        if let t = metaInflight[arcid] { return try await t.value }

        let client = try makeClient(profile: profile)
        let task = Task<ArchiveMetadata, Error> {
            try await limiter.withPermit {
                // Tankoubons have no /api/archives metadata; synthesize it from the tank object.
                if LANraragiID.isTankoubon(arcid) {
                    let tank = try await client.getTankoubon(id: arcid)
                    return ArchiveMetadata(
                        arcid: tank.id,
                        title: tank.name,
                        tags: tank.tags,
                        summary: tank.summary,
                        pagecount: nil,
                        progress: tank.progress
                    )
                }
                return try await client.getArchiveMetadata(arcid: arcid)
            }
        }

        metaInflight[arcid] = task
        defer { metaInflight[arcid] = nil }

        let m = try await task.value
        metaCache[arcid] = m
        return m
    }

    func archiveExists(profile: Profile, arcid: String) async throws -> Bool {
        do {
            _ = try await metadata(profile: profile, arcid: arcid, forceRefresh: true)
            return true
        } catch let LANraragiError.httpStatus(code, _) where code == 404 || code == 410 {
            // Only a definitive "gone" answer means the archive doesn't exist.
            // Transient server errors (5xx, etc.) must propagate so callers don't
            // prune user data based on a hiccup.
            metaCache[arcid] = nil
            pagesCache[arcid] = nil
            return false
        }
    }

    func updateMetadata(
        profile: Profile,
        arcid: String,
        title: String,
        tags: String,
        summary: String
    ) async throws -> ArchiveMetadata {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.updateArchiveMetadata(arcid: arcid, title: title, tags: tags, summary: summary)
        }

        // Refresh caches for this archive.
        metaCache[arcid] = nil
        let updated = try await metadata(profile: profile, arcid: arcid, forceRefresh: true)
        return updated
    }

    func updateThumbnail(
        profile: Profile,
        arcid: String,
        page: Int? = nil
    ) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.updateArchiveThumbnail(arcid: arcid, page: page)
        }
    }

    func randomArchives(
        profile: Profile,
        kind: MainPageCarouselKind,
        count: Int = 8
    ) async throws -> [ArchiveMetadata] {
        let client = try makeClient(profile: profile)
        let resp = try await limiter.withPermit {
            try await client.randomSearch(
                count: count,
                newOnly: kind.isNewOnly,
                untaggedOnly: kind.isUntaggedOnly
            )
        }
        return resp.data
    }

    func deleteArchive(profile: Profile, arcid: String) async throws {
        let client = try makeClient(profile: profile)
        do {
            try await limiter.withPermit {
                try await client.deleteArchive(arcid: arcid)
            }
        } catch let LANraragiError.httpStatus(code, _) where code == 404 || code == 410 {
            // Treat delete as idempotent if the archive is already gone server-side.
        }

        // Drop cached references for the deleted archive.
        metaCache[arcid] = nil
        pagesCache[arcid] = nil
        metaInflight[arcid]?.cancel()
        pagesInflight[arcid]?.cancel()
        metaInflight[arcid] = nil
        pagesInflight[arcid] = nil
    }
    func pageURLs(profile: Profile, arcid: String) async throws -> [URL] {
        if let p = pagesCache[arcid], p.count > 1 { return p }
        if let t = pagesInflight[arcid] { return try await t.value }

        let client = try makeClient(profile: profile)
        let task = Task<[URL], Error> {
            try await limiter.withPermit {
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

        let client = try makeClient(profile: profile)
        let task = Task<Data, Error> {
            try await limiter.withPermit {
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

    // MARK: - Tankoubons

    func listTankoubons(profile: Profile) async throws -> [Tankoubon] {
        let client = try makeClient(profile: profile)
        // Page -1 asks the server for the full unpaginated list.
        return try await limiter.withPermit {
            try await client.listTankoubons(page: -1).result
        }
    }

    @discardableResult
    func createTankoubon(profile: Profile, name: String, tankID: String? = nil) async throws -> String {
        let client = try makeClient(profile: profile)
        let id = try await limiter.withPermit {
            try await client.createTankoubon(name: name, tankID: tankID)
        }
        metaCache[id] = nil
        return id
    }

    func tankoubon(profile: Profile, tankID: String) async throws -> Tankoubon {
        let client = try makeClient(profile: profile)
        return try await limiter.withPermit {
            try await client.getTankoubon(id: tankID)
        }
    }

    func updateTankoubon(
        profile: Profile,
        tankID: String,
        archives: [String]? = nil,
        name: String? = nil,
        summary: String? = nil,
        tags: String? = nil
    ) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.updateTankoubon(
                id: tankID,
                archives: archives,
                name: name,
                summary: summary,
                tags: tags
            )
        }
        metaCache[tankID] = nil
    }

    func deleteTankoubon(profile: Profile, tankID: String) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.deleteTankoubon(id: tankID)
        }
        metaCache[tankID] = nil
    }

    func addArchiveToTankoubon(profile: Profile, tankID: String, arcid: String) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.addArchiveToTankoubon(tankID: tankID, arcid: arcid)
        }
        metaCache[tankID] = nil
    }

    func removeArchiveFromTankoubon(profile: Profile, tankID: String, arcid: String) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.removeArchiveFromTankoubon(tankID: tankID, arcid: arcid)
        }
        metaCache[tankID] = nil
    }

    // MARK: - Stamps

    func stampedPages(profile: Profile, arcid: String) async throws -> [Int] {
        let client = try makeClient(profile: profile)
        return try await limiter.withPermit {
            try await client.getStampedPages(arcid: arcid)
        }
    }

    func stamps(profile: Profile, arcid: String, page: Int) async throws -> [Stamp] {
        let client = try makeClient(profile: profile)
        return try await limiter.withPermit {
            try await client.getStamps(arcid: arcid, page: page)
        }
    }

    @discardableResult
    func addStamp(profile: Profile, arcid: String, page: Int, content: String, position: String) async throws -> String {
        let client = try makeClient(profile: profile)
        return try await limiter.withPermit {
            try await client.addStamp(arcid: arcid, page: page, content: content, position: position)
        }
    }

    func updateStamp(profile: Profile, stampID: String, content: String? = nil, position: String? = nil) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.updateStamp(id: stampID, content: content, position: position)
        }
    }

    func deleteStamp(profile: Profile, stampID: String) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.deleteStamp(id: stampID)
        }
    }

    /// Drops the cached client, API key, and all derived caches for a profile.
    /// Call after the profile's base URL or API key changes.
    func invalidateClient(profileID: UUID) {
        apiKeyByProfileID[profileID] = nil
        clientByProfileID[profileID] = nil
        metaCache.removeAll()
        pagesCache.removeAll()
        bytesCache.removeAllObjects()
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
                throw ArchiveLoaderError.missingAPIKey
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
