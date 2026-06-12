import Foundation

/// Limits the number of concurrently running operations.
///
/// Waiting tasks are cancellable: if a task is cancelled while queued for a
/// permit, `withPermit` throws `CancellationError` without running the operation.
public actor AsyncLimiter {
    private let limit: Int
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
        self.available = self.limit
    }

    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: idx).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if !waiters.isEmpty {
            // Transfer the permit directly to the next waiter.
            waiters.removeFirst().continuation.resume(returning: ())
            return
        }
        available = min(limit, available + 1)
    }
}
