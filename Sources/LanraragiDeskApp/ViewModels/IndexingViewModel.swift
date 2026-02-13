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

    func start(profile: Profile) {
        guard task == nil else { return }

        task = Task {
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
                            switch p.phase {
                            case .completed:
                                self?.status = .completed(p)
                            default:
                                self?.status = .running(p)
                            }
                        }
                    }
                )

                if Task.isCancelled {
                    return
                }
            } catch {
                if Task.isCancelled {
                    return
                }
                status = .failed(String(describing: error))
            }

            task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
                status = .idle
    }

    private static func indexDBURL() -> URL { AppPaths.indexDBURL() }
}
