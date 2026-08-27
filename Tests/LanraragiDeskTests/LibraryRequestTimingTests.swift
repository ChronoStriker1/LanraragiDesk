import Foundation
import LanraragiKit
import XCTest
@testable import LanraragiDesk

final class LibraryRequestTimingTests: XCTestCase {
    func testOperationsMapToThreeUserFacingCategories() {
        XCTAssertEqual(LibraryRequestTimingOperation.search.category, .search)
        XCTAssertEqual(LibraryRequestTimingOperation.archivePage.category, .archivePage)
        XCTAssertEqual(LibraryRequestTimingOperation.metadataRefresh.category, .metadata)
        XCTAssertEqual(LibraryRequestTimingOperation.metadataUpdate.category, .metadata)
        XCTAssertEqual(Set(LibraryRequestTimingCategory.allCases).count, 3)
    }

    func testDurationFormattingUsesReadableScales() {
        XCTAssertEqual(LibraryRequestTimingFormatter.duration(.milliseconds(482)), "482 ms")
        XCTAssertEqual(LibraryRequestTimingFormatter.duration(.milliseconds(1_234)), "1.23 s")
        XCTAssertEqual(LibraryRequestTimingFormatter.duration(.milliseconds(12_340)), "12.3 s")
        XCTAssertEqual(LibraryRequestTimingFormatter.duration(.milliseconds(62_500)), "1m 2.5 s")
    }

    func testHistoryIsNewestFirstAndBounded() {
        var history = LibraryRequestTimingHistory(capacity: 2)
        let first = timing(id: 1, operation: .search, outcome: .succeeded)
        let second = timing(id: 2, operation: .archivePage, outcome: .failed)
        let third = timing(id: 3, operation: .metadataRefresh, outcome: .cancelled)

        history.record(first)
        history.record(second)
        history.record(third)

        XCTAssertEqual(history.entries, [third, second])
        XCTAssertEqual(history.entries.map(\.outcome), [.cancelled, .failed])
    }

    func testNonPositiveCapacityStillRetainsLatestEntry() {
        var history = LibraryRequestTimingHistory(capacity: 0)
        history.record(timing(id: 1, operation: .search, outcome: .succeeded))
        history.record(timing(id: 2, operation: .archivePage, outcome: .succeeded))

        XCTAssertEqual(history.capacity, 1)
        XCTAssertEqual(history.entries.map(\.operation), [.archivePage])
    }

    private func timing(
        id: UInt8,
        operation: LibraryRequestTimingOperation,
        outcome: LibraryRequestTimingOutcome
    ) -> LibraryRequestTiming {
        LibraryRequestTiming(
            id: UUID(uuid: (id, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            operation: operation,
            duration: .milliseconds(Int64(id)),
            outcome: outcome,
            completedAt: Date(timeIntervalSince1970: TimeInterval(id))
        )
    }
}

@MainActor
final class LibraryRequestTimingGenerationTests: XCTestCase {
    func testStaleSuccessIsRecordedAsCancelledAndCurrentSuccessRemainsLatest() async {
        let loader = TimingControlledLibraryPageLoader()
        let viewModel = LibraryViewModel(pageLoader: { _, request in
            try await loader.load(request: request)
        })
        let profile = Profile(
            id: UUID(uuidString: "0D3B099D-3034-4219-8991-AD8869754A23")!,
            name: "Test",
            baseURL: URL(string: "https://example.test")!,
            language: "en-US"
        )

        viewModel.query = "old search"
        let oldLoad = Task { await viewModel.loadMore(profile: profile) }
        await loader.waitForRequestCount(1)

        viewModel.query = "new search"
        viewModel.refresh(profile: profile)
        await loader.waitForRequestCount(2)

        await loader.succeed(call: 0, arcids: ["stale"])
        _ = await oldLoad.value
        XCTAssertEqual(viewModel.requestTimingHistory.entries.first?.outcome, .cancelled)

        await loader.succeed(call: 1, arcids: ["current"])
        let finished = await eventually {
            viewModel.arcids == ["current"] && !viewModel.isLoading
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(viewModel.requestTimingHistory.entries.map(\.outcome), [.succeeded, .cancelled])
        XCTAssertEqual(viewModel.requestTimingHistory.entries.map(\.operation), [.search, .search])
    }

    func testFailureAndCancellationOutcomesAreRetained() async {
        let loader = TimingControlledLibraryPageLoader()
        let viewModel = LibraryViewModel(pageLoader: { _, request in
            try await loader.load(request: request)
        })
        let profile = Profile(
            name: "Test",
            baseURL: URL(string: "https://example.test")!,
            language: "en-US"
        )

        let failedLoad = Task { await viewModel.loadMore(profile: profile) }
        await loader.waitForRequestCount(1)
        await loader.fail(call: 0)
        _ = await failedLoad.value
        XCTAssertEqual(viewModel.requestTimingHistory.entries.first?.outcome, .failed)

        viewModel.refresh(profile: profile)
        await loader.waitForRequestCount(2)
        viewModel.query = "replacement"
        viewModel.refresh(profile: profile)
        await loader.waitForRequestCount(3)
        await loader.succeed(call: 1, arcids: ["cancelled"])
        await loader.succeed(call: 2, arcids: ["replacement"])

        let finished = await eventually {
            viewModel.arcids == ["replacement"] && !viewModel.isLoading
        }
        XCTAssertTrue(finished)
        XCTAssertTrue(viewModel.requestTimingHistory.entries.contains { $0.outcome == .cancelled })
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}

private enum TimingTestError: Error, Sendable {
    case failure
}

private actor TimingControlledLibraryPageLoader {
    typealias Request = LibraryViewModel.SearchRequest
    typealias Result = LibraryViewModel.PageLoadResult

    private var requests: [Request] = []
    private var pending: [Int: CheckedContinuation<Result, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func load(request: Request) async throws -> Result {
        let call = requests.count
        requests.append(request)
        resumeWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
        }
    }

    func waitForRequestCount(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func succeed(call: Int, arcids: [String]) {
        let response = ArchiveSearch(
            data: arcids.map(ArchiveIdOnly.init),
            recordsFiltered: arcids.count,
            recordsTotal: arcids.count
        )
        pending.removeValue(forKey: call)?.resume(
            returning: .init(response: response)
        )
    }

    func fail(call: Int) {
        pending.removeValue(forKey: call)?.resume(throwing: TimingTestError.failure)
    }

    private func resumeWaiters() {
        let ready = waiters.filter { requests.count >= $0.0 }
        waiters.removeAll { requests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }
}
