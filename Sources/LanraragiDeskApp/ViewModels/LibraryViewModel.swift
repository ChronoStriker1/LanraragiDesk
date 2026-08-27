import Foundation
import LanraragiKit

@MainActor
final class LibraryViewModel: ObservableObject {
    enum Layout: String, CaseIterable, Identifiable {
        case grid
        case list

        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case newestAdded
        case title

        var id: String { rawValue }

        var title: String {
            switch self {
            case .newestAdded: return "Newest added"
            case .title: return "Title"
            }
        }
    }

    @Published var query: String = ""
    @Published var layout: Layout = .grid
    @Published var sort: Sort = .newestAdded
    @Published var newOnly: Bool = false
    @Published var untaggedOnly: Bool = false
    @Published var categoryID: String = ""
    /// When enabled (server default), Tankoubons appear in results in place of their member archives.
    @Published var groupTanks: Bool = true

    @Published private(set) var categories: [LanraragiKit.Category] = []
    @Published private(set) var categoriesStatusText: String?
    @Published private(set) var isLoadingCategories: Bool = false

    @Published private(set) var arcids: [String] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isLoadingAll: Bool = false
    @Published private(set) var errorText: String?
    @Published private(set) var bannerText: String?

    struct SearchRequest: Equatable, Sendable {
        let start: Int
        let query: String
        let categoryID: String
        let newOnly: Bool
        let untaggedOnly: Bool
        let sort: Sort
        let groupTanks: Bool
        let knownDateAddedSortSupport: Bool?
    }

    struct PageLoadResult: Sendable {
        let response: ArchiveSearch
        let dateAddedSortSupport: Bool?
        let fellBackToTitle: Bool

        init(
            response: ArchiveSearch,
            dateAddedSortSupport: Bool? = nil,
            fellBackToTitle: Bool = false
        ) {
            self.response = response
            self.dateAddedSortSupport = dateAddedSortSupport
            self.fellBackToTitle = fellBackToTitle
        }
    }

    typealias PageLoader = @MainActor (Profile, SearchRequest) async throws -> PageLoadResult

    private struct LoadGeneration {
        let id: UUID
        let profileID: Profile.ID
        let query: String
        let categoryID: String
        let newOnly: Bool
        let untaggedOnly: Bool
        var sort: Sort
        let groupTanks: Bool
    }

    private var start: Int = 0
    private var totalFiltered: Int = 0
    private let pageSize: Int = 100
    private var reachedEnd: Bool = false
    private var supportsDateAddedSort: Bool?
    private let clientProvider: LANraragiClientProvider
    private let pageLoader: PageLoader?
    private var loadGeneration: LoadGeneration?
    private var activeLoadGenerationID: UUID?

    init(
        clientProvider: LANraragiClientProvider = .shared,
        pageLoader: PageLoader? = nil
    ) {
        self.clientProvider = clientProvider
        self.pageLoader = pageLoader
    }

    func refresh(profile: Profile) {
        let generation = makeGeneration(profile: profile)
        loadGeneration = generation
        activeLoadGenerationID = nil
        start = 0
        totalFiltered = 0
        reachedEnd = false
        arcids = []
        isLoading = false
        bannerText = nil
        errorText = nil
        Task { await loadMore(profile: profile, generationID: generation.id) }
    }

    func loadCategories(profile: Profile) async {
        guard !isLoadingCategories else { return }
        isLoadingCategories = true
        defer { isLoadingCategories = false }

        do {
            let client = try makeClient(profile: profile)
            let resp = try await client.listCategories()
            let cleaned = resp
                .map { LanraragiKit.Category(id: $0.id.trimmingCharacters(in: .whitespacesAndNewlines), name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), pinned: $0.pinned) }
                .filter { !$0.id.isEmpty && !$0.name.isEmpty }

            let sorted = cleaned.sorted { a, b in
                if a.pinned != b.pinned { return a.pinned && !b.pinned }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            categories = sorted
            categoriesStatusText = nil

            if !categoryID.isEmpty, !sorted.contains(where: { $0.id == categoryID }) {
                categoryID = ""
            }
        } catch {
            if Task.isCancelled { return }
            categories = []
            categoriesStatusText = ErrorPresenter.short(error)
        }
    }

    func loadMore(profile: Profile) async {
        let generation: LoadGeneration
        if let existing = loadGeneration, existing.profileID == profile.id {
            generation = existing
        } else {
            let newGeneration = makeGeneration(profile: profile)
            loadGeneration = newGeneration
            generation = newGeneration
        }
        await loadMore(profile: profile, generationID: generation.id)
    }

    private func loadMore(profile: Profile, generationID: UUID) async {
        guard let generation = loadGeneration, generation.id == generationID else { return }
        guard activeLoadGenerationID != generationID else { return }
        guard !reachedEnd else { return }

        let request = SearchRequest(
            start: start,
            query: generation.query,
            categoryID: generation.categoryID,
            newOnly: generation.newOnly,
            untaggedOnly: generation.untaggedOnly,
            sort: generation.sort,
            groupTanks: generation.groupTanks,
            knownDateAddedSortSupport: supportsDateAddedSort
        )

        activeLoadGenerationID = generationID
        isLoading = true
        defer {
            if activeLoadGenerationID == generationID {
                activeLoadGenerationID = nil
                if loadGeneration?.id == generationID {
                    isLoading = false
                }
            }
        }

        do {
            let result = try await loadPage(profile: profile, request: request)
            guard loadGeneration?.id == generationID,
                  activeLoadGenerationID == generationID else { return }

            if let dateAddedSortSupport = result.dateAddedSortSupport {
                supportsDateAddedSort = dateAddedSortSupport
            }
            if result.fellBackToTitle {
                loadGeneration?.sort = .title
                sort = .title
                bannerText = "Server doesn’t support sorting by date added; using Title instead."
            }
            apply(resp: result.response)
        } catch {
            guard loadGeneration?.id == generationID,
                  activeLoadGenerationID == generationID,
                  !Task.isCancelled else { return }
            errorText = ErrorPresenter.short(error)
        }
    }

    func loadAll(profile: Profile) async -> [String] {
        guard !isLoadingAll else { return arcids }
        isLoadingAll = true
        defer { isLoadingAll = false }

        while !reachedEnd {
            if Task.isCancelled { break }
            await loadMore(profile: profile)
            if isLoading { break }
        }
        return arcids
    }

    private func apply(resp: ArchiveSearch) {
        let new = resp.data.map(\.arcid)
        arcids.append(contentsOf: new)
        totalFiltered = resp.recordsFiltered
        start += new.count
        if arcids.count >= totalFiltered || new.isEmpty {
            reachedEnd = true
        }
    }

    private func loadPage(profile: Profile, request: SearchRequest) async throws -> PageLoadResult {
        if let pageLoader {
            return try await pageLoader(profile, request)
        }

        let client = try await clientProvider.client(for: profile)
        guard request.sort == .newestAdded else {
            return PageLoadResult(response: try await fetchSearch(client: client, request: request, sort: .title))
        }

        let capability: Bool?
        if let knownDateAddedSortSupport = request.knownDateAddedSortSupport {
            capability = knownDateAddedSortSupport
        } else {
            capability = await detectDateAddedSortSupport(client: client)
        }

        if capability == false {
            return PageLoadResult(
                response: try await fetchSearch(client: client, request: request, sort: .title),
                dateAddedSortSupport: false,
                fellBackToTitle: true
            )
        }

        do {
            return PageLoadResult(
                response: try await fetchSearch(client: client, request: request, sort: .newestAdded),
                dateAddedSortSupport: capability
            )
        } catch let LANraragiError.httpStatus(code, _) where code == 400 || code == 422 {
            // Server reported no date_added support even after capability probing. Fall back safely.
            return PageLoadResult(
                response: try await fetchSearch(client: client, request: request, sort: .title),
                dateAddedSortSupport: false,
                fellBackToTitle: true
            )
        }
    }

    private func detectDateAddedSortSupport(client: LANraragiClient) async -> Bool? {
        do {
            _ = try await client.search(
                start: 0,
                filter: "",
                category: "",
                newOnly: false,
                untaggedOnly: false,
                sortBy: "date_added",
                order: "desc"
            )
            return true
        } catch let LANraragiError.httpStatus(code, _) where code == 400 || code == 422 {
            return false
        } catch {
            return nil
        }
    }

    private func fetchSearch(
        client: LANraragiClient,
        request: SearchRequest,
        sort: Sort
    ) async throws -> ArchiveSearch {
        let (sortBy, order): (String, String) = {
            switch sort {
            case .newestAdded:
                return ("date_added", "desc")
            case .title:
                return ("title", "asc")
            }
        }()

        return try await client.search(
            start: request.start,
            filter: request.query,
            category: request.categoryID,
            newOnly: request.newOnly,
            untaggedOnly: request.untaggedOnly,
            sortBy: sortBy,
            order: order,
            groupByTanks: request.groupTanks
        )
    }

    private func makeGeneration(profile: Profile) -> LoadGeneration {
        LoadGeneration(
            id: UUID(),
            profileID: profile.id,
            query: query,
            categoryID: categoryID,
            newOnly: newOnly,
            untaggedOnly: untaggedOnly,
            sort: sort,
            groupTanks: groupTanks
        )
    }

    private func makeClient(profile: Profile) throws -> LANraragiClient {
        let account = "apiKey.\(profile.id.uuidString)"
        let apiKeyString = try KeychainService.getString(account: account)
        let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

        return LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: apiKey,
            acceptLanguage: profile.language,
            maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
        ))
    }
}
