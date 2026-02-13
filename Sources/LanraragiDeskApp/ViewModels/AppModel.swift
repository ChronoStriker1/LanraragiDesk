import Combine
import Foundation
import LanraragiKit

@MainActor
final class AppModel: ObservableObject {
    let profileStore: ProfileStore
    @Published var selectedProfileID: Profile.ID?

    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var indexing: IndexingViewModel
    @Published var duplicates: DuplicateScanViewModel

    private var cancellables: Set<AnyCancellable> = []

    init() {
        self.profileStore = ProfileStore()
        self.indexing = IndexingViewModel()
        self.duplicates = DuplicateScanViewModel()

        // SwiftUI doesn't automatically observe nested ObservableObjects through a parent EnvironmentObject.
        // Forward child changes so views reading `appModel.profileStore...` / `appModel.indexing...` update.
        profileStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        indexing.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        duplicates.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    enum ConnectionStatus: Equatable {
        case idle
        case testing
        case ok(ServerInfo)
        case unauthorized
        case failed(String)
    }

    var selectedProfile: Profile? {
        guard let id = selectedProfileID else { return nil }
        return profileStore.profiles.first(where: { $0.id == id })
    }

    func selectFirstIfNeeded() {
        if selectedProfileID == nil {
            selectedProfileID = profileStore.profiles.first?.id
        }
    }

    func testConnection() async {
        guard let profile = selectedProfile else { return }
        connectionStatus = .testing

        let account = "apiKey.\(profile.id.uuidString)"
        let apiKeyString = (try? KeychainService.getString(account: account)) ?? nil
        let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

        let client = LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: apiKey,
            acceptLanguage: profile.language
        ))

        do {
            let info = try await client.getServerInfo()
            connectionStatus = .ok(info)
        } catch LANraragiError.unauthorized {
            connectionStatus = .unauthorized
        } catch {
            connectionStatus = .failed(String(describing: error))
        }
    }
}
