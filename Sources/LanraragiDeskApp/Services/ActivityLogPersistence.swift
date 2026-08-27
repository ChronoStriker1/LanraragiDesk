import Foundation

actor ActivityLogPersistence {
    typealias Writer = @Sendable (Data, URL) throws -> Void

    private struct PendingSnapshot {
        let events: [ActivityEvent]
        let revision: UInt64
    }

    private let fileURL: URL
    private let debounceDelay: Duration
    private let writer: Writer
    private var newestRevision: UInt64 = 0
    private var persistedRevision: UInt64?
    private var pendingSnapshot: PendingSnapshot?
    private var debounceTask: Task<Void, Never>?

    init(
        fileURL: URL,
        debounceDelay: Duration,
        writer: @escaping Writer = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) {
        self.fileURL = fileURL
        self.debounceDelay = debounceDelay
        self.writer = writer
    }

    func schedule(events: [ActivityEvent], revision: UInt64) {
        guard revision >= newestRevision else { return }
        guard persistedRevision != revision else { return }

        newestRevision = revision
        pendingSnapshot = PendingSnapshot(events: events, revision: revision)
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceDelay] in
            do {
                try await Task.sleep(for: debounceDelay)
            } catch {
                return
            }
            await self?.persistScheduledSnapshot(revision: revision)
        }
    }

    func flush(events: [ActivityEvent], revision: UInt64) throws {
        guard revision >= newestRevision else { return }
        guard pendingSnapshot != nil || persistedRevision != revision else { return }

        newestRevision = revision
        pendingSnapshot = PendingSnapshot(events: events, revision: revision)
        debounceTask?.cancel()
        debounceTask = nil
        try persistPendingSnapshot(revision: revision)
    }

    nonisolated func flushSynchronously(events: [ActivityEvent], revision: UInt64) {
        let completion = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) { [self] in
            defer { completion.signal() }
            do {
                try await flush(events: events, revision: revision)
            } catch {
                Self.log(error: error, fileURL: fileURL)
            }
        }
        completion.wait()
    }

    private func persistScheduledSnapshot(revision: UInt64) {
        do {
            try persistPendingSnapshot(revision: revision)
        } catch {
            Self.log(error: error, fileURL: fileURL)
        }
    }

    private func persistPendingSnapshot(revision: UInt64) throws {
        guard let pendingSnapshot, pendingSnapshot.revision == revision else { return }

        let data = try JSONEncoder().encode(pendingSnapshot.events)
        try writer(data, fileURL)
        persistedRevision = revision
        self.pendingSnapshot = nil
    }

    nonisolated private static func log(error: Error, fileURL: URL) {
        NSLog(
            "ActivityStore: failed to persist activity log at %@: %@",
            fileURL.path,
            String(describing: error)
        )
    }
}
