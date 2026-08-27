import Foundation
import LanraragiKit

struct ArchiveLoaderInFlightOperation<Value: Sendable>: Sendable {
    let id: UUID
    let task: Task<Value, Error>
}

struct ArchiveLoaderInFlightRegistry<Key: Hashable, Value: Sendable> {
    private var operations: [Key: ArchiveLoaderInFlightOperation<Value>] = [:]

    subscript(key: Key) -> ArchiveLoaderInFlightOperation<Value>? {
        operations[key]
    }

    @discardableResult
    mutating func insert(
        _ task: Task<Value, Error>,
        for key: Key
    ) -> ArchiveLoaderInFlightOperation<Value> {
        let operation = ArchiveLoaderInFlightOperation(id: UUID(), task: task)
        operations[key] = operation
        return operation
    }

    @discardableResult
    mutating func removeValue(for key: Key, ownedBy id: UUID) -> Bool {
        guard operations[key]?.id == id else { return false }
        operations[key] = nil
        return true
    }

    mutating func cancelAndRemoveValue(for key: Key) {
        operations.removeValue(forKey: key)?.task.cancel()
    }

    mutating func cancelAndRemoveAll() {
        for operation in operations.values {
            operation.task.cancel()
        }
        operations.removeAll()
    }
}

struct ArchiveLoaderFetchOverrides: Sendable {
    let metadata: @Sendable (String) async throws -> ArchiveMetadata
    let archiveFiles: @Sendable (String, Bool) async throws -> ArchiveFilesResponse
    let absoluteURL: @Sendable (String) throws -> URL
}

actor ArchiveLoader {
    enum ArchiveLoaderError: Error {
        case missingAPIKey
    }

    private let limiter = AsyncLimiter(limit: 4)

    private var apiKeyByProfileID: [UUID: String] = [:]
    private var clientByProfileID: [UUID: LANraragiClient] = [:]

    private var metaCache: [String: ArchiveMetadata] = [:]
    private var metaInflight = ArchiveLoaderInFlightRegistry<String, ArchiveMetadata>()

    private var pagesCache: [String: [URL]] = [:]
    private var pagesInflight = ArchiveLoaderInFlightRegistry<String, [URL]>()

    private let bytesCache = NSCache<NSString, NSData>()
    private var bytesInflight = ArchiveLoaderInFlightRegistry<String, Data>()

    private let maxCachedBytes = 8 * 1024 * 1024
    private let fetchOverrides: ArchiveLoaderFetchOverrides?

    init(fetchOverrides: ArchiveLoaderFetchOverrides? = nil) {
        self.fetchOverrides = fetchOverrides
        bytesCache.totalCostLimit = 512 * 1024 * 1024 // ~512MB
    }

    func metadata(profile: Profile, arcid: String, forceRefresh: Bool = false) async throws -> ArchiveMetadata {
        if !forceRefresh {
            if let metadata = metaCache[arcid] { return metadata }
            if let operation = metaInflight[arcid] {
                return try await operation.task.value
            }
        }

        let fetchMetadata: @Sendable () async throws -> ArchiveMetadata
        if let metadataOverride = fetchOverrides?.metadata {
            fetchMetadata = {
                try await metadataOverride(arcid)
            }
        } else {
            let client = try makeClient(profile: profile)
            fetchMetadata = {
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
        let task = Task<ArchiveMetadata, Error> {
            try await limiter.withPermit {
                try await fetchMetadata()
            }
        }

        // A forced refresh replaces the shared slot without cancelling the old
        // operation. Existing waiters can still receive its result, but only the
        // replacement is allowed to publish into the cache. The last known-good
        // cached value remains available until that replacement succeeds.
        let operation = metaInflight.insert(task, for: arcid)

        do {
            let metadata = try await task.value
            if metaInflight.removeValue(for: arcid, ownedBy: operation.id) {
                metaCache[arcid] = metadata
            }
            return metadata
        } catch {
            metaInflight.removeValue(for: arcid, ownedBy: operation.id)
            throw error
        }
    }

    func archiveExists(profile: Profile, arcid: String) async throws -> Bool {
        do {
            _ = try await metadata(profile: profile, arcid: arcid, forceRefresh: true)
            return true
        } catch let LANraragiError.httpStatus(code, _) where code == 404 || code == 410 {
            // Only a definitive "gone" answer means the archive doesn't exist.
            // Transient server errors (5xx, etc.) must propagate so callers don't
            // prune user data based on a hiccup.
            invalidateArchiveCaches(arcid: arcid)
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
        invalidateMetadataCache(arcid: arcid)
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
        invalidateArchiveCaches(arcid: arcid)
    }
    func pageURLs(profile: Profile, arcid: String) async throws -> [URL] {
        if let pages = pagesCache[arcid] { return pages }
        if let operation = pagesInflight[arcid] {
            return try await operation.task.value
        }

        let fetchArchiveFiles: @Sendable (Bool) async throws -> ArchiveFilesResponse
        let makeAbsoluteURL: @Sendable (String) throws -> URL
        if let fetchOverrides {
            fetchArchiveFiles = { force in
                try await fetchOverrides.archiveFiles(arcid, force)
            }
            makeAbsoluteURL = fetchOverrides.absoluteURL
        } else {
            let client = try makeClient(profile: profile)
            fetchArchiveFiles = { force in
                try await client.getArchiveFiles(arcid: arcid, force: force)
            }
            makeAbsoluteURL = { rawURL in
                try client.makeAbsoluteURL(from: rawURL)
            }
        }
        let task = Task<[URL], Error> {
            try await limiter.withPermit {
                let resp: ArchiveFilesResponse
                do {
                    let initial = try await fetchArchiveFiles(false)
                    if initial.pages.count <= 1 {
                        // Some servers return only the first extracted page unless forced.
                        let forced = try await fetchArchiveFiles(true)
                        resp = forced.pages.count > initial.pages.count ? forced : initial
                    } else {
                        resp = initial
                    }
                } catch let LANraragiError.httpStatus(code, _) where code == 400 {
                    // Some LANraragi setups return 400 unless file listing is forced (e.g. stale extraction state).
                    resp = try await fetchArchiveFiles(true)
                }
                var out: [URL] = []
                out.reserveCapacity(resp.pages.count)
                for s in resp.pages {
                    out.append(try makeAbsoluteURL(s))
                }
                return out
            }
        }

        let operation = pagesInflight.insert(task, for: arcid)

        do {
            let pages = try await task.value
            if pagesInflight.removeValue(for: arcid, ownedBy: operation.id) {
                // Even a single-page result is verified here: the request task has
                // already completed the initial + forced listing path above.
                pagesCache[arcid] = pages
            }
            return pages
        } catch {
            pagesInflight.removeValue(for: arcid, ownedBy: operation.id)
            throw error
        }
    }

    func bytes(profile: Profile, url: URL) async throws -> Data {
        let key = url.absoluteString as NSString
        if let b = bytesCache.object(forKey: key) {
            return Data(referencing: b)
        }

        let inflightKey = String(key)
        if let operation = bytesInflight[inflightKey] {
            return try await operation.task.value
        }

        let client = try makeClient(profile: profile)
        let task = Task<Data, Error> {
            try await limiter.withPermit {
                return try await client.fetchBytes(url: url)
            }
        }

        let operation = bytesInflight.insert(task, for: inflightKey)

        do {
            let data = try await task.value
            if bytesInflight.removeValue(for: inflightKey, ownedBy: operation.id),
               data.count <= maxCachedBytes {
                bytesCache.setObject(data as NSData, forKey: key, cost: data.count)
            }
            return data
        } catch {
            bytesInflight.removeValue(for: inflightKey, ownedBy: operation.id)
            throw error
        }
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
        invalidateMetadataCache(arcid: id)
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
        invalidateMetadataCache(arcid: tankID)
    }

    func deleteTankoubon(profile: Profile, tankID: String) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.deleteTankoubon(id: tankID)
        }
        invalidateMetadataCache(arcid: tankID)
    }

    func addArchiveToTankoubon(profile: Profile, tankID: String, arcid: String) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.addArchiveToTankoubon(tankID: tankID, arcid: arcid)
        }
        invalidateMetadataCache(arcid: tankID)
    }

    func removeArchiveFromTankoubon(profile: Profile, tankID: String, arcid: String) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.removeArchiveFromTankoubon(tankID: tankID, arcid: arcid)
        }
        invalidateMetadataCache(arcid: tankID)
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
        metaInflight.cancelAndRemoveAll()
        pagesInflight.cancelAndRemoveAll()
        bytesInflight.cancelAndRemoveAll()
    }

    private func invalidateArchiveCaches(arcid: String) {
        invalidateMetadataCache(arcid: arcid)
        pagesCache[arcid] = nil
        pagesInflight.cancelAndRemoveValue(for: arcid)
    }

    private func invalidateMetadataCache(arcid: String) {
        metaCache[arcid] = nil
        metaInflight.cancelAndRemoveValue(for: arcid)
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
