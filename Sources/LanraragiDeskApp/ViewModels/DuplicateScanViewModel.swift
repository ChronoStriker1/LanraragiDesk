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

    // Tuning knobs
    @Published var includeExactChecksum: Bool = true
    @Published var includeApproximate: Bool = true
    @Published var strictness: Strictness = .balanced

    let thumbnails = ThumbnailLoader()
    let archives = ArchiveLoader()

    private var task: Task<Void, Never>?
    private var runID: UUID?

    func start(profile: Profile) {
        guard task == nil else { return }

        let rid = UUID()
        runID = rid

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
                    maxConnectionsPerHost: 8
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
            } catch {
                if Task.isCancelled { return }
                if runID == rid {
                    status = .failed(String(describing: error))
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
            return
        }

        // Keep the Scan tab list fresh; newest decision should appear first.
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
    }

    func clearNotDuplicateDecisions(profile: Profile) {
        do {
            let store = try IndexStore(configuration: .init(url: AppPaths.indexDBURL()))
            try store.clearNotDuplicatePairs(profileID: profile.id)
        } catch {
            status = .failed("Failed to clear exclusions: \(error)")
            return
        }
        notMatches = []
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
        }
    }

    func removeNotDuplicatePair(profile: Profile, pair: IndexStore.NotDuplicatePair) {
        do {
            let store = try IndexStore(configuration: .init(url: AppPaths.indexDBURL()))
            try store.removeNotDuplicatePair(profileID: profile.id, arcidA: pair.arcidA, arcidB: pair.arcidB)
        } catch {
            status = .failed("Failed to remove exclusion: \(error)")
            return
        }
        notMatches.removeAll { $0 == pair }
    }

    func deleteArchive(profile: Profile, arcid: String) async throws {
        let account = "apiKey.\(profile.id.uuidString)"
        let apiKeyString = try KeychainService.getString(account: account)
        let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

        let client = LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: apiKey,
            acceptLanguage: profile.language,
            maxConnectionsPerHost: 4
        ))

        try await client.deleteArchive(arcid: arcid)

        if var r = result {
            r.pairs.removeAll { $0.arcidA == arcid || $0.arcidB == arcid }
            r.groups.removeAll { $0.contains(arcid) }
            result = r
            resultRevision &+= 1
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        runID = nil
        status = .idle
    }

    func clearResults() {
        cancel()
        result = nil
        resultRevision &+= 1
    }
}
