import Foundation

@MainActor
final class SavedQueryStore: ObservableObject {
    @Published private(set) var queries: [SavedBatchQuery] = []

    init() {
        load()
    }

    func save(_ query: SavedBatchQuery) {
        if let idx = queries.firstIndex(where: { $0.id == query.id }) {
            queries[idx] = query
        } else {
            queries.append(query)
        }
        persist()
    }

    func delete(id: UUID) {
        queries.removeAll { $0.id == id }
        persist()
    }

    func queries(for profileID: UUID) -> [SavedBatchQuery] {
        queries.filter { $0.profileID == profileID }
    }

    private func load() {
        let url = AppPaths.savedBatchQueriesURL()
        guard let data = try? Data(contentsOf: url) else {
            queries = []
            return
        }
        queries = (try? JSONDecoder().decode([SavedBatchQuery].self, from: data)) ?? []
    }

    private func persist() {
        let url = AppPaths.savedBatchQueriesURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let data = try JSONEncoder().encode(queries)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best-effort.
        }
    }
}
