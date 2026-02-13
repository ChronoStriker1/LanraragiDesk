import Foundation

public struct IndexerConfig: Sendable {
    public var concurrency: Int
    public var resumeFromLastStart: Bool
    public var skipExisting: Bool
    public var noFallbackThumbnails: Bool

    public init(
        concurrency: Int = 6,
        resumeFromLastStart: Bool = true,
        skipExisting: Bool = true,
        noFallbackThumbnails: Bool = true
    ) {
        self.concurrency = max(1, concurrency)
        self.resumeFromLastStart = resumeFromLastStart
        self.skipExisting = skipExisting
        self.noFallbackThumbnails = noFallbackThumbnails
    }
}

public struct IndexerProgress: Sendable {
    public enum Phase: Sendable, Equatable {
        case starting
        case enumerating(total: Int)
        case indexing(total: Int)
        case completed(total: Int)
    }

    public var phase: Phase
    public var startOffset: Int
    public var total: Int
    public var seen: Int
    public var queued: Int
    public var completed: Int
    public var indexed: Int
    public var skipped: Int
    public var failed: Int
    public var currentArcid: String?

    public init(
        phase: Phase,
        startOffset: Int,
        total: Int,
        seen: Int,
        queued: Int,
        completed: Int,
        indexed: Int,
        skipped: Int,
        failed: Int,
        currentArcid: String?
    ) {
        self.phase = phase
        self.startOffset = startOffset
        self.total = total
        self.seen = seen
        self.queued = queued
        self.completed = completed
        self.indexed = indexed
        self.skipped = skipped
        self.failed = failed
        self.currentArcid = currentArcid
    }
}

public struct FingerprintIndexer {
    public init() {}

    public func run(
        profileID: UUID,
        client: LANraragiClient,
        store: IndexStore,
        baseURL: URL,
        language: String,
        config: IndexerConfig = IndexerConfig(),
        progress: @escaping @Sendable (IndexerProgress) -> Void
    ) async throws {
        try store.upsertProfile(profileID: profileID, baseURL: baseURL, language: language)

        let startOffset = config.resumeFromLastStart ? (try store.getLastStart(profileID: profileID)) : 0

        let counters = Counters(startOffset: startOffset)
        let ticker = ProgressTicker(minInterval: .milliseconds(500))
        let limiter = AsyncLimiter(limit: config.concurrency)

        progress(await counters.snapshot(phase: .starting, total: 0, currentArcid: nil))

        var start = startOffset

        // First page establishes total.
        var page = try await client.search(start: start)
        let total = page.recordsTotal
        progress(await counters.snapshot(phase: .enumerating(total: total), total: total, currentArcid: nil))

        while true {
            try Task.checkCancellation()
            if page.data.isEmpty {
                break
            }

            progress(await counters.snapshot(phase: .indexing(total: total), total: total, currentArcid: nil))

            try await withThrowingTaskGroup(of: Void.self) { group in
                for item in page.data {
                    try Task.checkCancellation()
                    let arcid = item.arcid

                    await counters.didSee()

                    if config.skipExisting {
                        let has = try store.hasAnyFingerprint(profileID: profileID, arcid: arcid)
                        if has {
                            await counters.didSkip()
                            continue
                        }
                    }

                    await counters.didQueue()

                    group.addTask {
                        await limiter.withPermit {
                            do {
                                let thumb = try await client.fetchCoverThumbnailBytes(
                                    arcid: arcid,
                                    noFallback: config.noFallbackThumbnails
                                )

                                let fp = try Fingerprinter.compute(from: thumb)
                                let now = Int64(Date().timeIntervalSince1970)

                                for (kind, crop, hash) in fp.records {
                                    try store.upsertFingerprint(.init(
                                        profileID: profileID,
                                        arcid: arcid,
                                        kind: kind,
                                        crop: crop,
                                        hash64: hash,
                                        aspectRatio: fp.aspectRatio,
                                        thumbChecksum: fp.checksumSHA256,
                                        updatedAt: now
                                    ))
                                }

                                await counters.didIndex()
                            } catch {
                                await counters.didFail()
                            }

                            await counters.didComplete()

                            if await ticker.shouldEmit() {
                                progress(await counters.snapshot(
                                    phase: .indexing(total: total),
                                    total: total,
                                    currentArcid: arcid
                                ))
                            }
                        }
                    }
                }

                try await group.waitForAll()
            }

            start += page.data.count
            try store.setLastStart(profileID: profileID, lastStart: start)

            if start >= total {
                break
            }

            page = try await client.search(start: start)
        }

        progress(await counters.snapshot(phase: .completed(total: total), total: total, currentArcid: nil))
    }
}

private actor Counters {
    private let startOffset: Int

    private var seen: Int = 0
    private var queued: Int = 0
    private var completed: Int = 0
    private var indexed: Int = 0
    private var skipped: Int = 0
    private var failed: Int = 0

    init(startOffset: Int) {
        self.startOffset = startOffset
    }

    func didSee() {
        seen += 1
    }

    func didQueue() {
        queued += 1
    }

    func didComplete() {
        completed += 1
    }

    func didIndex() {
        indexed += 1
    }

    func didSkip() {
        skipped += 1
    }

    func didFail() {
        failed += 1
    }

    func snapshot(phase: IndexerProgress.Phase, total: Int, currentArcid: String?) -> IndexerProgress {
        IndexerProgress(
            phase: phase,
            startOffset: startOffset,
            total: total,
            seen: seen,
            queued: queued,
            completed: completed,
            indexed: indexed,
            skipped: skipped,
            failed: failed,
            currentArcid: currentArcid
        )
    }
}

private actor ProgressTicker {
    private let minInterval: Duration
    private let clock = ContinuousClock()
    private var last: ContinuousClock.Instant?

    init(minInterval: Duration) {
        self.minInterval = minInterval
    }

    func shouldEmit() -> Bool {
        let now = clock.now
        defer { last = now }
        guard let last else { return true }
        return last.duration(to: now) >= minInterval
    }
}

private actor AsyncLimiter {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        self.available = max(1, limit)
    }

    func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }

        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
            return
        }
        available = min(limit, available + 1)
    }
}
