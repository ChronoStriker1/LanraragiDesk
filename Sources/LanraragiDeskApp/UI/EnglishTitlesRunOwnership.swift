import Foundation

struct EnglishTitlesRunOwnership {
    struct Run: Equatable, Sendable {
        fileprivate let id: UUID
    }

    private(set) var activeRun: Run?
    private(set) var isCancellationRequested = false

    var isBusy: Bool {
        activeRun != nil
    }

    mutating func begin(id: UUID = UUID()) -> Run? {
        guard activeRun == nil else { return nil }

        let run = Run(id: id)
        activeRun = run
        isCancellationRequested = false
        return run
    }

    func owns(_ run: Run) -> Bool {
        activeRun == run
    }

    func acceptsUpdates(from run: Run) -> Bool {
        owns(run) && !isCancellationRequested
    }

    @discardableResult
    mutating func requestCancellation(of run: Run) -> Bool {
        guard owns(run), !isCancellationRequested else { return false }
        isCancellationRequested = true
        return true
    }

    @discardableResult
    mutating func finish(_ run: Run) -> Bool {
        guard owns(run) else { return false }
        activeRun = nil
        isCancellationRequested = false
        return true
    }
}
