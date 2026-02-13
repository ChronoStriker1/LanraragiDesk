import Foundation
import LanraragiKit

@MainActor
final class AppModel: ObservableObject {
    @Published var profileStore = ProfileStore()
    @Published var selectedProfileID: Profile.ID?

    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var indexing = IndexingViewModel()

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
