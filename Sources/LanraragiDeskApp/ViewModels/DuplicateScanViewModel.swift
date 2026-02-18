import Foundation
import LanraragiKit

@MainActor
final class DuplicateScanViewModel: ObservableObject {
    enum Strictness: Int, Sendable {
        case strict = 0
        case balanced = 1
        case loose = 2
    }

    enum Status {
        case idle
        case running(String)
        case completed(DuplicateScanStats)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var result: DuplicateScanResult?
    @Published private(set) var resultRevision: Int = 0
    @Published private(set) var notMatches: [IndexStore.NotDuplicatePair] = []
    @Published private(set) var hasUndoableNotMatchChange: Bool = false

    // Tuning knobs
    @Published var includeExactChecksum: Bool = true
    @Published var includeApproximate: Bool = true
    @Published var strictness: Strictness = .balanced

    let thumbnails: ThumbnailLoader
    let archives: ArchiveLoader
    var activitySink: ((ActivityEvent) -> Void)?

    private var task: Task<Void, Never>?
    private var runID: UUID?
    private var notMatchUndoStack: [NotMatchUndoAction] = []

    private enum NotMatchUndoAction {
        case removed(IndexStore.NotDuplicatePair)
        case cleared([IndexStore.NotDuplicatePair])
    }

    init(thumbnails: ThumbnailLoader = ThumbnailLoader(), archives: ArchiveLoader = ArchiveLoader()) {
        self.thumbnails = thumbnails
        self.archives = archives
    }

    private func log(_ kind: ActivityEvent.Kind, _ title: String, detail: String? = nil) {
        activitySink?(.init(kind: kind, title: title, detail: detail))
    }

    func start(profile: Profile) {
        guard task == nil else {
            log(.warning, "Duplicate scan already running")
            return
        }

        let rid = UUID()
        runID = rid

        let strictnessLabel: String = {
            switch strictness {
            case .strict: return "Strict"
            case .balanced: return "Balanced"
            case .loose: return "Loose"
            }
        }()

        log(
            .action,
            "Duplicate scan started",
            detail: "Mode: \(strictnessLabel) • Exact: \(includeExactChecksum ? "on" : "off") • Approx: \(includeApproximate ? "on" : "off")"
        )

        status = .running("Resetting local index…")
        result = nil

        task = Task {
            defer {
                Task { @MainActor in
                    if self.runID == rid {
                        self.task = nil
                        self.runID = nil
                    }
                }
            }

            do {
                let store = try IndexStore(configuration: .init(url: AppPaths.indexDBURL()))

                // Each scan starts from a clean fingerprint index, but keeps user-made exclusions.
                try store.resetFingerprintIndex(keepNotDuplicates: true)

                // Always run the indexer first. If the index is already complete, this should be quick.
                status = .running("Indexing covers…")

                let account = "apiKey.\(profile.id.uuidString)"
                let apiKeyString = try KeychainService.getString(account: account)
                let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

                let client = LANraragiClient(configuration: .init(
                    baseURL: profile.baseURL,
                    apiKey: apiKey,
                    acceptLanguage: profile.language,
                    maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
                ))

                let indexer = FingerprintIndexer()
                try await indexer.run(
                    profileID: profile.id,
                    client: client,
                    store: store,
                    baseURL: profile.baseURL,
                    language: profile.language,
                    config: IndexerConfig(concurrency: 4, resumeFromLastStart: true, skipExisting: true, noFallbackThumbnails: false),
                    progress: { [weak self] p in
                        Task { @MainActor in
                            guard let self, self.runID == rid else { return }
                            let total = max(1, p.total)
                            let processed = min(total, p.startOffset + p.seen)
                            let text = "Indexing covers: \(processed)/\(total) (\(p.failed) failed)"
                            self.status = .running(text)
                        }
                    }
                )

                status = .running("Loading fingerprints…")
                let fps = try store.loadScanFingerprints(profileID: profile.id)

                status = .running("Loading exclusions…")
                let notDup = try store.loadNotDuplicatePairs(profileID: profile.id)

                status = .running("Scanning for duplicates…")

                let (dHashThreshold, aHashThreshold, bucketMaxSize): (Int, Int, Int) = {
                    switch strictness {
                    case .strict: return (4, 4, 48)
                    case .balanced: return (6, 6, 64)
                    case .loose: return (9, 9, 96)
                    }
                }()

                let cfg = DuplicateScanConfig(
                    includeExactChecksum: includeExactChecksum,
                    includeApproximate: includeApproximate,
                    dHashThreshold: dHashThreshold,
                    aHashThreshold: aHashThreshold,
                    bucketMaxSize: bucketMaxSize
                )

                let res = try await DuplicateFinder.scan(
                    fingerprints: fps,
                    notDuplicates: notDup,
                    config: cfg
                )

                if Task.isCancelled { return }
                if runID != rid { return }
                result = res
                status = .completed(res.stats)
                resultRevision &+= 1
                log(
                    .action,
                    "Duplicate scan completed",
                    detail: "Groups: \(res.groups.count) • Pairs: \(res.pairs.count) • Archives: \(res.stats.archives) • \(String(format: "%.1fs", res.stats.durationSeconds))"
                )
            } catch {
                if Task.isCancelled { return }
                if runID == rid {
                    status = .failed(String(describing: error))
                    log(.error, "Duplicate scan failed", detail: String(describing: error))
                }
            }
        }
    }

    func markNotDuplicate(profile: Profile, pair: DuplicateScanResult.Pair) {
        // Persist immediately so future scans won't show this again.
        do {
            let store = try IndexStore(configuration: .init(url: AppPaths.indexDBURL()))
            try store.addNotDuplicatePair(profileID: profile.id, arcidA: pair.arcidA, arcidB: pair.arcidB)
        } catch {
            status = .failed("Failed to save exclusion: \(error)")
            log(.error, "Failed to save Not a match pair", detail: "\(pair.arcidA) • \(pair.arcidB)\n\(error)")
            return
        }

        // Keep the Manage tab list fresh; newest decision should appear first.
        let now = Int64(Date().timeIntervalSince1970)
        let notPair = IndexStore.NotDuplicatePair(arcidA: pair.arcidA, arcidB: pair.arcidB, createdAt: now)
        notMatches.removeAll { $0 == notPair }
        notMatches.insert(notPair, at: 0)

        // Update the in-memory result to keep the UI responsive.
        if var r = result {
            r.pairs.removeAll { p in
                (p.arcidA == pair.arcidA && p.arcidB == pair.arcidB) ||
                (p.arcidA == pair.arcidB && p.arcidB == pair.arcidA)
            }
            result = r
            resultRevision &+= 1
        }

        log(.action, "Marked Not a match", detail: "\(pair.arcidA) • \(pair.arcidB)")
    }

    func clearNotDuplicateDecisions(profile: Profile) {
        let previousCount = notMatches.count
        if previousCount > 0 {
            notMatchUndoStack.append(.cleared(notMatches))
            hasUndoableNotMatchChange = !notMatchUndoStack.isEmpty
        }
        do {
            let store = try IndexStore(configuration: .init(url: AppPaths.indexDBURL()))
            try store.clearNotDuplicatePairs(profileID: profile.id)
        } catch {
            status = .failed("Failed to clear exclusions: \(error)")
            log(.error, "Failed to clear Not a match pairs", detail: String(describing: error))
            return
        }
        notMatches = []
        log(.action, "Cleared Not a match pairs", detail: "\(previousCount) pairs")
    }

    func loadNotDuplicatePairs(profile: Profile) async {
        do {
            let store = try IndexStore(configuration: .init(url: AppPaths.indexDBURL()))
            let set = try store.loadNotDuplicatePairs(profileID: profile.id)
            notMatches = set.sorted { a, b in
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                if a.arcidA != b.arcidA { return a.arcidA < b.arcidA }
                return a.arcidB < b.arcidB
            }
        } catch {
            status = .failed("Failed to load exclusions: \(error)")
            log(.error, "Failed to load Not a match pairs", detail: String(describing: error))
        }
    }

    func removeNotDuplicatePair(profile: Profile, pair: IndexStore.NotDuplicatePair) {
        do {
            let store = try IndexStore(configuration: .init(url: AppPaths.indexDBURL()))
            try store.removeNotDuplicatePair(profileID: profile.id, arcidA: pair.arcidA, arcidB: pair.arcidB)
        } catch {
            status = .failed("Failed to remove exclusion: \(error)")
            log(.error, "Failed to remove Not a match pair", detail: "\(pair.arcidA) • \(pair.arcidB)\n\(error)")
            return
        }
        notMatchUndoStack.append(.removed(pair))
        hasUndoableNotMatchChange = !notMatchUndoStack.isEmpty
        notMatches.removeAll { $0 == pair }
        log(.action, "Removed Not a match pair", detail: "\(pair.arcidA) • \(pair.arcidB)")
    }

    func undoLastNotDuplicateChange(profile: Profile) {
        guard let action = notMatchUndoStack.popLast() else { return }
        hasUndoableNotMatchChange = !notMatchUndoStack.isEmpty

        do {
            let store = try IndexStore(configuration: .init(url: AppPaths.indexDBURL()))
            switch action {
            case .removed(let pair):
                try store.addNotDuplicatePair(profileID: profile.id, arcidA: pair.arcidA, arcidB: pair.arcidB)
                if !notMatches.contains(pair) {
                    notMatches.insert(pair, at: 0)
                }
                log(.action, "Undo removed Not a match pair", detail: "\(pair.arcidA) • \(pair.arcidB)")
            case .cleared(let pairs):
                for pair in pairs {
                    try store.addNotDuplicatePair(profileID: profile.id, arcidA: pair.arcidA, arcidB: pair.arcidB)
                }
                mergeRestoredNotMatches(pairs)
                log(.action, "Undo cleared Not a match pairs", detail: "\(pairs.count) pairs")
            }
        } catch {
            status = .failed("Failed to undo Not a match change: \(error)")
            log(.error, "Failed to undo Not a match change", detail: String(describing: error))
        }
    }

    func deleteArchive(profile: Profile, arcid: String) async throws {
        do {
            try await archives.deleteArchive(profile: profile, arcid: arcid)
        } catch {
            log(.error, "Delete archive failed", detail: "\(arcid)\n\(error)")
            throw error
        }

        await thumbnails.invalidate(profile: profile, arcid: arcid)

        let removedLocalNotMatches = notMatches.reduce(into: 0) { count, pair in
            if pair.arcidA == arcid || pair.arcidB == arcid {
                count += 1
            }
        }
        if removedLocalNotMatches > 0 {
            notMatches.removeAll { $0.arcidA == arcid || $0.arcidB == arcid }
        }

        do {
            let removedStoredNotMatches = try purgeStoredNotDuplicatePairs(profile: profile, containing: arcid)
            let removedTotal = max(removedLocalNotMatches, removedStoredNotMatches)
            if removedTotal > 0 {
                log(.action, "Cleaned Not a match pairs", detail: "\(arcid) • removed \(removedTotal)")
            }
        } catch {
            log(.warning, "Failed to clean Not a match pairs", detail: "\(arcid)\n\(error)")
        }

        if var r = result {
            r.pairs.removeAll { $0.arcidA == arcid || $0.arcidB == arcid }
            r.groups = makeGroups(from: r.pairs)
            result = r
            resultRevision &+= 1
        }

        log(.action, "Deleted archive", detail: arcid)
    }

    func cancel() {
        let hadRunningTask = (task != nil)
        task?.cancel()
        task = nil
        runID = nil
        status = .idle
        if hadRunningTask {
            log(.warning, "Duplicate scan cancelled")
        }
    }

    func clearResults() {
        cancel()
        result = nil
        resultRevision &+= 1
        log(.action, "Cleared duplicate scan results")
    }

    private func makeGroups(from pairs: [DuplicateScanResult.Pair]) -> [[String]] {
        guard !pairs.isEmpty else { return [] }

        var adjacency: [String: Set<String>] = [:]
        adjacency.reserveCapacity(pairs.count * 2)

        for pair in pairs {
            adjacency[pair.arcidA, default: []].insert(pair.arcidB)
            adjacency[pair.arcidB, default: []].insert(pair.arcidA)
        }

        var visited: Set<String> = []
        visited.reserveCapacity(adjacency.count)

        var groups: [[String]] = []
        groups.reserveCapacity(adjacency.count)

        for arcid in adjacency.keys.sorted() {
            if visited.contains(arcid) { continue }

            var stack: [String] = [arcid]
            visited.insert(arcid)

            var component: [String] = []
            component.reserveCapacity(4)

            while let current = stack.popLast() {
                component.append(current)
                for next in adjacency[current, default: []] where !visited.contains(next) {
                    visited.insert(next)
                    stack.append(next)
                }
            }

            if component.count > 1 {
                groups.append(component.sorted())
            }
        }

        groups.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            return (a.first ?? "") < (b.first ?? "")
        }
        return groups
    }

    private func purgeStoredNotDuplicatePairs(profile: Profile, containing arcid: String) throws -> Int {
        let store = try IndexStore(configuration: .init(url: AppPaths.indexDBURL()))
        let stored = try store.loadNotDuplicatePairs(profileID: profile.id)

        var removed = 0
        for pair in stored where pair.arcidA == arcid || pair.arcidB == arcid {
            try store.removeNotDuplicatePair(profileID: profile.id, arcidA: pair.arcidA, arcidB: pair.arcidB)
            removed += 1
        }

        return removed
    }

    private func mergeRestoredNotMatches(_ pairs: [IndexStore.NotDuplicatePair]) {
        if pairs.isEmpty { return }
        for pair in pairs where !notMatches.contains(pair) {
            notMatches.append(pair)
        }
        notMatches.sort { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            if a.arcidA != b.arcidA { return a.arcidA < b.arcidA }
            return a.arcidB < b.arcidB
        }
    }
}
