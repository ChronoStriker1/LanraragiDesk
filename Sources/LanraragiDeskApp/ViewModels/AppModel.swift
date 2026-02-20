import Combine
import Foundation
import LanraragiKit

@MainActor
final class AppModel: ObservableObject {
    struct LibrarySearchRequest: Equatable {
        let id: UUID
        let profileID: Profile.ID
        let query: String
    }

    let profileStore: ProfileStore
    let savedQueryStore: SavedQueryStore
    @Published var selectedProfileID: Profile.ID?
    @Published var profileEditorMode: ProfileEditorMode?
    @Published var librarySearchRequest: LibrarySearchRequest?
    @Published var activeReaderRoute: ReaderRoute?

    @Published var connectionStatus: ConnectionStatus = .idle
    @Published var indexing: IndexingViewModel
    @Published var duplicates: DuplicateScanViewModel
    let archives: ArchiveLoader
    let thumbnails: ThumbnailLoader
    let activity: ActivityStore
    let tagSuggestions: TagSuggestionStore
    let selection: SelectionModel

    private var cancellables: Set<AnyCancellable> = []

    init() {
        self.profileStore = ProfileStore()
        self.savedQueryStore = SavedQueryStore()
        self.archives = ArchiveLoader()
        self.thumbnails = ThumbnailLoader()
        self.activity = ActivityStore()
        self.tagSuggestions = TagSuggestionStore()
        self.selection = SelectionModel()
        self.indexing = IndexingViewModel()
        self.duplicates = DuplicateScanViewModel(thumbnails: thumbnails, archives: archives)
        self.duplicates.activitySink = { [weak self] event in
            self?.activity.add(event)
        }

        // SwiftUI doesn't automatically observe nested ObservableObjects through a parent EnvironmentObject.
        // Forward child changes so views reading `appModel.profileStore...` / `appModel.indexing...` update.
        profileStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        savedQueryStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        indexing.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        duplicates.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        activity.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        selection.objectWillChange
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
            acceptLanguage: profile.language,
            maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
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

    func requestLibrarySearch(profileID: Profile.ID, query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        librarySearchRequest = LibrarySearchRequest(id: UUID(), profileID: profileID, query: trimmed)
    }

    func consumeLibrarySearchRequest(id: UUID) {
        guard librarySearchRequest?.id == id else { return }
        librarySearchRequest = nil
    }

    func setActiveReader(profileID: Profile.ID, arcid: String) {
        let trimmed = arcid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeReaderRoute = ReaderRoute(profileID: profileID, arcid: trimmed)
    }
}
