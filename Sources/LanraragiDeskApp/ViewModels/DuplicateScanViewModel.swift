import Foundation
import LanraragiKit

@MainActor
final class DuplicateScanViewModel: ObservableObject {
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
    @Published var dHashThreshold: Int = 6
    @Published var aHashThreshold: Int = 6
    @Published var bucketMaxSize: Int = 64

    let thumbnails = ThumbnailLoader()

    private var task: Task<Void, Never>?
    private var runID: UUID?

    func start(profile: Profile) {
        guard task == nil else { return }

        let rid = UUID()
        runID = rid

        status = .running("Opening index…")
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

                status = .running("Loading fingerprints…")
                let fps = try store.loadScanFingerprints(profileID: profile.id)

                status = .running("Loading exclusions…")
                let notDup = try store.loadNotDuplicatePairs(profileID: profile.id)

                status = .running("Scanning…")
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
