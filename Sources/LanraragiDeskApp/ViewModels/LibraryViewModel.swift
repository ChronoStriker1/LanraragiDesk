import Foundation
import LanraragiKit

@MainActor
final class LibraryViewModel: ObservableObject {
    enum Layout: String, CaseIterable, Identifiable {
        case grid
        case list

        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
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

    @Published private(set) var categories: [LanraragiKit.Category] = []
    @Published private(set) var categoriesStatusText: String?
    @Published private(set) var isLoadingCategories: Bool = false

    @Published private(set) var arcids: [String] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorText: String?
    @Published private(set) var bannerText: String?

    private var start: Int = 0
    private var totalFiltered: Int = 0
    private let pageSize: Int = 100
    private var reachedEnd: Bool = false

    func refresh(profile: Profile) {
        start = 0
        totalFiltered = 0
        reachedEnd = false
        arcids = []
        bannerText = nil
        errorText = nil
        Task { await loadMore(profile: profile) }
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
        guard !isLoading else { return }
        guard !reachedEnd else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let client = try makeClient(profile: profile)
            let reqSort = sort

            do {
                let resp = try await fetchSearch(client: client, start: start, sort: reqSort)
                apply(resp: resp)
            } catch let LANraragiError.httpStatus(code, _) where reqSort == .newestAdded && (code == 400 || code == 422) {
                // Server doesn't support sorting by date_added; fall back to Title.
                sort = .title
                bannerText = "Server doesn’t support sorting by date added; using Title instead."
                let resp = try await fetchSearch(client: client, start: start, sort: .title)
                apply(resp: resp)
            }
        } catch {
            if Task.isCancelled { return }
            errorText = ErrorPresenter.short(error)
        }
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

    private func fetchSearch(client: LANraragiClient, start: Int, sort: Sort) async throws -> ArchiveSearch {
        let (sortBy, order): (String, String) = {
            switch sort {
            case .newestAdded:
                return ("date_added", "desc")
            case .title:
                return ("title", "asc")
            }
        }()

        return try await client.search(
            start: start,
            filter: query,
            category: categoryID,
            newOnly: newOnly,
            untaggedOnly: untaggedOnly,
            sortBy: sortBy,
            order: order
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
