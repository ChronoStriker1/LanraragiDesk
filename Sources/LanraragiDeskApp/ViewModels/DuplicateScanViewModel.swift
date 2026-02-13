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
    @Published var showingResults: Bool = false

    // Tuning knobs
    @Published var includeExactChecksum: Bool = true
    @Published var includeApproximate: Bool = true
    @Published var strictness: Strictness = .balanced

    let thumbnails = ThumbnailLoader()

    private var task: Task<Void, Never>?
    private var runID: UUID?

    func start(profile: Profile) {
        guard task == nil else { return }

        let rid = UUID()
        runID = rid

        status = .running("Preparing local index…")
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

                // Always run the indexer first. If the index is already complete, this should be quick.
                status = .running("Updating index (this can take a while on first run)…")

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
                showingResults = true
            } catch {
                if Task.isCancelled { return }
                if runID == rid {
                    status = .failed(String(describing: error))
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        runID = nil
        status = .idle
    }
}
