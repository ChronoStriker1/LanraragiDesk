import Foundation

private enum SavedQueryStoreError: LocalizedError {
    case readFailed(fileName: String, reason: String)
    case corruptBackupFailed(fileName: String, reason: String)
    case writeFailed(fileName: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let fileName, let reason):
            return "Saved queries could not be read from \(fileName): \(reason)"
        case .corruptBackupFailed(let fileName, let reason):
            return "Saved queries are corrupt and could not be backed up to \(fileName): \(reason)"
        case .writeFailed(let fileName, let reason):
            return "Saved queries could not be written to \(fileName): \(reason)"
        }
    }
}

@MainActor
final class SavedQueryStore: ObservableObject {
    @Published private(set) var queries: [SavedBatchQuery] = []
    @Published private(set) var errorMessage: String?

    private let fileURL: URL
    private var persistenceBlock: SavedQueryStoreError?
    private var recoveryNotice: String?

    init() {
        self.fileURL = AppPaths.savedBatchQueriesURL()
        load()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func save(_ query: SavedBatchQuery) throws {
        var updatedQueries = queries
        if let idx = updatedQueries.firstIndex(where: { $0.id == query.id }) {
            updatedQueries[idx] = query
        } else {
            updatedQueries.append(query)
        }
        try persist(updatedQueries)
        queries = updatedQueries
        errorMessage = recoveryNotice
    }

    func delete(id: UUID) throws {
        var updatedQueries = queries
        updatedQueries.removeAll { $0.id == id }
        try persist(updatedQueries)
        queries = updatedQueries
        errorMessage = recoveryNotice
    }

    func queries(for profileID: UUID) -> [SavedBatchQuery] {
        queries.filter { $0.profileID == profileID }
    }

    func clearError() {
        recoveryNotice = nil
        errorMessage = nil
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            queries = []
            return
        } catch {
            let storeError = SavedQueryStoreError.readFailed(
                fileName: fileURL.lastPathComponent,
                reason: error.localizedDescription
            )
            persistenceBlock = storeError
            errorMessage = storeError.localizedDescription
            NSLog("SavedQueryStore: %@", storeError.localizedDescription)
            queries = []
            return
        }

        do {
            queries = try JSONDecoder().decode([SavedBatchQuery].self, from: data)
        } catch {
            backUpCorruptData(data, decodingError: error)
            queries = []
        }
    }

    private func backUpCorruptData(_ data: Data, decodingError: Error) {
        let backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt.json")
        do {
            try data.write(to: backupURL, options: [.atomic])
            let notice = "Saved queries were corrupt. The original data was preserved in \(backupURL.lastPathComponent)."
            recoveryNotice = notice
            errorMessage = notice
            NSLog(
                "SavedQueryStore: failed to decode %@ (%@); backed up to %@",
                fileURL.path,
                String(describing: decodingError),
                backupURL.path
            )
        } catch {
            let storeError = SavedQueryStoreError.corruptBackupFailed(
                fileName: backupURL.lastPathComponent,
                reason: error.localizedDescription
            )
            persistenceBlock = storeError
            errorMessage = storeError.localizedDescription
            NSLog(
                "SavedQueryStore: failed to decode %@ and preserve a backup: %@",
                fileURL.path,
                String(describing: error)
            )
        }
    }

    private func persist(_ updatedQueries: [SavedBatchQuery]) throws {
        if let persistenceBlock {
            errorMessage = persistenceBlock.localizedDescription
            throw persistenceBlock
        }

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(updatedQueries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            let storeError = SavedQueryStoreError.writeFailed(
                fileName: fileURL.lastPathComponent,
                reason: error.localizedDescription
            )
            errorMessage = storeError.localizedDescription
            throw storeError
        }
    }
}
