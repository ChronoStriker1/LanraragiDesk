import Foundation
import LanraragiKit

struct ArchiveLoaderInFlightOperation<Value: Sendable>: Sendable {
    let id: UUID
    let generation: UInt64
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
        for key: Key,
        generation: UInt64 = 0
    ) -> ArchiveLoaderInFlightOperation<Value> {
        let operation = ArchiveLoaderInFlightOperation(
            id: UUID(),
            generation: generation,
            task: task
        )
        operations[key] = operation
        return operation
    }

    @discardableResult
    mutating func removeValue(
        for key: Key,
        ownedBy id: UUID,
        generation: UInt64? = nil
    ) -> Bool {
        guard let operation = operations[key], operation.id == id else { return false }
        if let generation, operation.generation != generation { return false }
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

    mutating func cancelAndRemoveAll(where shouldRemove: (Key) -> Bool) {
        let keys = operations.keys.filter(shouldRemove)
        for key in keys {
            operations.removeValue(forKey: key)?.task.cancel()
        }
    }
}

private struct ArchiveLoaderResourceKey: Hashable, Sendable {
    let profileID: UUID
    let resource: String
}

struct ArchiveLoaderFetchOverrides: Sendable {
    let metadata: @Sendable (String) async throws -> ArchiveMetadata
    let archiveFiles: @Sendable (String, Bool) async throws -> ArchiveFilesResponse
    let absoluteURL: @Sendable (String) throws -> URL
    let bytes: @Sendable (URL) async throws -> Data
}

actor ArchiveLoader {
    enum ArchiveLoaderError: Error {
        case missingAPIKey
    }

    private let limiter = AsyncLimiter(limit: 4)

    private var apiKeyByProfileID: [UUID: String] = [:]
    private var clientByProfileID: [UUID: LANraragiClient] = [:]
    private var clientGenerationByProfileID: [UUID: UInt64] = [:]

    private var metaCache: [ArchiveLoaderResourceKey: ArchiveMetadata] = [:]
    private var metaInflight = ArchiveLoaderInFlightRegistry<ArchiveLoaderResourceKey, ArchiveMetadata>()

    private var pagesCache: [ArchiveLoaderResourceKey: [URL]] = [:]
    private var pagesInflight = ArchiveLoaderInFlightRegistry<ArchiveLoaderResourceKey, [URL]>()

    private let bytesCache = NSCache<NSString, NSData>()
    private var bytesCacheKeysByProfileID: [UUID: Set<String>] = [:]
    private var bytesInflight = ArchiveLoaderInFlightRegistry<ArchiveLoaderResourceKey, Data>()

    private let maxCachedBytes = 8 * 1024 * 1024
    private let fetchOverrides: ArchiveLoaderFetchOverrides?

    init(fetchOverrides: ArchiveLoaderFetchOverrides? = nil) {
        self.fetchOverrides = fetchOverrides
        bytesCache.totalCostLimit = 512 * 1024 * 1024 // ~512MB
    }

    func metadata(profile: Profile, arcid: String, forceRefresh: Bool = false) async throws -> ArchiveMetadata {
        let key = ArchiveLoaderResourceKey(profileID: profile.id, resource: arcid)
        let generation = clientGeneration(for: profile.id)
        if !forceRefresh {
            if let metadata = metaCache[key] { return metadata }
            if let operation = metaInflight[key], operation.generation == generation {
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
        let operation = metaInflight.insert(task, for: key, generation: generation)

        do {
            let metadata = try await task.value
            if clientGeneration(for: profile.id) == generation,
               metaInflight.removeValue(
                   for: key,
                   ownedBy: operation.id,
                   generation: generation
               ) {
                metaCache[key] = metadata
            }
            return metadata
        } catch {
            if clientGeneration(for: profile.id) == generation {
                metaInflight.removeValue(
                    for: key,
                    ownedBy: operation.id,
                    generation: generation
                )
            }
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
            invalidateArchiveCaches(profileID: profile.id, arcid: arcid)
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
        invalidateMetadataCache(profileID: profile.id, arcid: arcid)
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
        invalidateArchiveCaches(profileID: profile.id, arcid: arcid)
    }
    func pageURLs(profile: Profile, arcid: String) async throws -> [URL] {
        let key = ArchiveLoaderResourceKey(profileID: profile.id, resource: arcid)
        let generation = clientGeneration(for: profile.id)
        if let pages = pagesCache[key] { return pages }
        if let operation = pagesInflight[key], operation.generation == generation {
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

        let operation = pagesInflight.insert(task, for: key, generation: generation)

        do {
            let pages = try await task.value
            if clientGeneration(for: profile.id) == generation,
               pagesInflight.removeValue(
                   for: key,
                   ownedBy: operation.id,
                   generation: generation
               ) {
                // Even a single-page result is verified here: the request task has
                // already completed the initial + forced listing path above.
                pagesCache[key] = pages
            }
            return pages
        } catch {
            if clientGeneration(for: profile.id) == generation {
                pagesInflight.removeValue(
                    for: key,
                    ownedBy: operation.id,
                    generation: generation
                )
            }
            throw error
        }
    }

    func bytes(profile: Profile, url: URL) async throws -> Data {
        let cacheKeyString = "\(profile.id.uuidString)/\(url.absoluteString)"
        let cacheKey = cacheKeyString as NSString
        let key = ArchiveLoaderResourceKey(profileID: profile.id, resource: url.absoluteString)
        let generation = clientGeneration(for: profile.id)
        if let b = bytesCache.object(forKey: cacheKey) {
            return Data(referencing: b)
        }

        if let operation = bytesInflight[key], operation.generation == generation {
            return try await operation.task.value
        }

        let fetchBytes: @Sendable () async throws -> Data
        if let bytesOverride = fetchOverrides?.bytes {
            fetchBytes = {
                try await bytesOverride(url)
            }
        } else {
            let client = try makeClient(profile: profile)
            fetchBytes = {
                try await client.fetchBytes(url: url)
            }
        }
        let task = Task<Data, Error> {
            try await limiter.withPermit {
                try await fetchBytes()
            }
        }

        let operation = bytesInflight.insert(task, for: key, generation: generation)

        do {
            let data = try await task.value
            if clientGeneration(for: profile.id) == generation,
               bytesInflight.removeValue(
                   for: key,
                   ownedBy: operation.id,
                   generation: generation
               ),
               data.count <= maxCachedBytes {
                bytesCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                bytesCacheKeysByProfileID[profile.id, default: []].insert(cacheKeyString)
            }
            return data
        } catch {
            if clientGeneration(for: profile.id) == generation {
                bytesInflight.removeValue(
                    for: key,
                    ownedBy: operation.id,
                    generation: generation
                )
            }
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
        invalidateMetadataCache(profileID: profile.id, arcid: id)
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
        invalidateMetadataCache(profileID: profile.id, arcid: tankID)
    }

    func deleteTankoubon(profile: Profile, tankID: String) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.deleteTankoubon(id: tankID)
        }
        invalidateMetadataCache(profileID: profile.id, arcid: tankID)
    }

    func addArchiveToTankoubon(profile: Profile, tankID: String, arcid: String) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.addArchiveToTankoubon(tankID: tankID, arcid: arcid)
        }
        invalidateMetadataCache(profileID: profile.id, arcid: tankID)
    }

    func removeArchiveFromTankoubon(profile: Profile, tankID: String, arcid: String) async throws {
        let client = try makeClient(profile: profile)
        try await limiter.withPermit {
            try await client.removeArchiveFromTankoubon(tankID: tankID, arcid: arcid)
        }
        invalidateMetadataCache(profileID: profile.id, arcid: tankID)
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
        clientGenerationByProfileID[profileID] = clientGeneration(for: profileID) &+ 1
        apiKeyByProfileID[profileID] = nil
        clientByProfileID[profileID] = nil
        metaCache = metaCache.filter { $0.key.profileID != profileID }
        pagesCache = pagesCache.filter { $0.key.profileID != profileID }
        for key in bytesCacheKeysByProfileID.removeValue(forKey: profileID) ?? [] {
            bytesCache.removeObject(forKey: key as NSString)
        }
        metaInflight.cancelAndRemoveAll { $0.profileID == profileID }
        pagesInflight.cancelAndRemoveAll { $0.profileID == profileID }
        bytesInflight.cancelAndRemoveAll { $0.profileID == profileID }
    }

    private func invalidateArchiveCaches(profileID: UUID, arcid: String) {
        let key = ArchiveLoaderResourceKey(profileID: profileID, resource: arcid)
        invalidateMetadataCache(profileID: profileID, arcid: arcid)
        pagesCache[key] = nil
        pagesInflight.cancelAndRemoveValue(for: key)
    }

    private func invalidateMetadataCache(profileID: UUID, arcid: String) {
        let key = ArchiveLoaderResourceKey(profileID: profileID, resource: arcid)
        metaCache[key] = nil
        metaInflight.cancelAndRemoveValue(for: key)
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
