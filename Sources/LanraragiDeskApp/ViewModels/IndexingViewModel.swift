import Foundation
import LanraragiKit

@MainActor
final class IndexingViewModel: ObservableObject {
    enum Status {
        case idle
        case running(IndexerProgress)
        case completed(IndexerProgress)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private var task: Task<Void, Never>?
    private var store: IndexStore?
    private var runID: UUID?

    func start(profile: Profile) {
        guard task == nil else { return }

        let rid = UUID()
        runID = rid
        status = .running(.init(
            phase: .starting,
            startOffset: 0,
            total: 0,
            seen: 0,
            queued: 0,
            completed: 0,
            indexed: 0,
            skipped: 0,
            failed: 0,
            currentArcid: nil
        ))

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
                let store = try IndexStore(configuration: .init(url: Self.indexDBURL()))
                self.store = store

                let account = "apiKey.\(profile.id.uuidString)"
                let apiKeyString = try KeychainService.getString(account: account)
                let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

                let client = LANraragiClient(configuration: .init(
                    baseURL: profile.baseURL,
                    apiKey: apiKey,
                    acceptLanguage: profile.language
                ))

                let indexer = FingerprintIndexer()

                try await indexer.run(
                    profileID: profile.id,
                    client: client,
                    store: store,
                    baseURL: profile.baseURL,
                    language: profile.language,
                    config: IndexerConfig(),
                    progress: { [weak self] p in
                        Task { @MainActor in
                            guard let self, self.runID == rid else { return }
                            switch p.phase {
                            case .completed:
                                self.status = .completed(p)
                            default:
                                self.status = .running(p)
                            }
                        }
                    }
                )

            } catch {
                if Task.isCancelled {
                    return
                }
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

    func resetIndexFiles() {
        cancel()
        store = nil
        do {
            let s = try IndexStore(configuration: .init(url: Self.indexDBURL()))
            // Keep "Not a match" decisions; they are user effort.
            try s.resetFingerprintIndex(keepNotDuplicates: true)
        } catch {
            status = .failed("Reset failed: \(error)")
        }
    }

    private static func indexDBURL() -> URL { AppPaths.indexDBURL() }
}
