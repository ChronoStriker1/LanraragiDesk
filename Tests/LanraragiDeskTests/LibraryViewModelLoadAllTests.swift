import Foundation
import LanraragiKit
import XCTest
@testable import LanraragiDesk

@MainActor
final class LibraryViewModelLoadAllTests: XCTestCase {
    func testImmediateFailureStopsAfterOneRequestAndAllowsLaterRetry() async {
        let loader = ScriptedLoadAllPageLoader(steps: [
            .failure,
            .page(arcids: ["recovered"], recordsFiltered: 1),
        ])
        let viewModel = makeViewModel(loader: loader)

        let selected = await viewModel.loadAll(profile: makeProfile())
        let failedRequestCount = await loader.requestCount

        XCTAssertEqual(selected, [])
        XCTAssertEqual(failedRequestCount, 1)
        XCTAssertNotNil(viewModel.errorText)

        let retryOutcome = await viewModel.loadMore(profile: makeProfile())
        let requestCountAfterRetry = await loader.requestCount
        XCTAssertEqual(retryOutcome, .reachedEnd)
        XCTAssertEqual(viewModel.arcids, ["recovered"])
        XCTAssertEqual(requestCountAfterRetry, 2)
    }

    func testFailureAfterOnePageReturnsPartialResultsWithoutRetrying() async {
        let loader = ScriptedLoadAllPageLoader(steps: [
            .page(arcids: ["first"], recordsFiltered: 3),
            .failure,
        ])
        let viewModel = makeViewModel(loader: loader)

        let selected = await viewModel.loadAll(profile: makeProfile())
        let requestCount = await loader.requestCount

        XCTAssertEqual(selected, ["first"])
        XCTAssertEqual(viewModel.arcids, ["first"])
        XCTAssertEqual(requestCount, 2)
        XCTAssertNotNil(viewModel.errorText)
    }

    func testSuccessPaginatesUntilTheServerReportedTotalIsLoaded() async {
        let loader = ScriptedLoadAllPageLoader(steps: [
            .page(arcids: ["first", "second"], recordsFiltered: 3),
            .page(arcids: ["third"], recordsFiltered: 3),
        ])
        let viewModel = makeViewModel(loader: loader)

        let selected = await viewModel.loadAll(profile: makeProfile())
        let requestCount = await loader.requestCount
        let requestStarts = await loader.requestStarts

        XCTAssertEqual(selected, ["first", "second", "third"])
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(requestStarts, [0, 2])
        XCTAssertNil(viewModel.errorText)
    }

    func testAlreadyLoadingGenerationMakesLoadAllReturnWithoutSpinning() async {
        let loader = ControlledLoadAllPageLoader()
        let viewModel = makeViewModel(loader: loader)
        let profile = makeProfile()

        let pendingLoad = Task { await viewModel.loadMore(profile: profile) }
        await loader.waitForRequestCount(1)

        let selected = await viewModel.loadAll(profile: profile)
        let requestCount = await loader.requestCount

        XCTAssertEqual(selected, [])
        XCTAssertEqual(requestCount, 1)

        await loader.succeed(call: 0, arcids: ["first"], recordsFiltered: 1)
        let pendingOutcome = await pendingLoad.value
        XCTAssertEqual(pendingOutcome, .reachedEnd)
    }

    func testRefreshDuringLoadAllTerminatesOldGenerationWithoutSelectingNewResults() async {
        let loader = ControlledLoadAllPageLoader()
        let viewModel = makeViewModel(loader: loader)
        let profile = makeProfile()

        viewModel.query = "old"
        let oldLoadAll = Task { await viewModel.loadAll(profile: profile) }
        await loader.waitForRequestCount(1)

        viewModel.query = "new"
        viewModel.refresh(profile: profile)
        await loader.waitForRequestCount(2)

        await loader.succeed(call: 0, arcids: ["stale"], recordsFiltered: 2)
        let oldSelection = await oldLoadAll.value
        let requestCount = await loader.requestCount

        XCTAssertEqual(oldSelection, [])
        XCTAssertEqual(requestCount, 2)

        await loader.succeed(call: 1, arcids: ["current"], recordsFiltered: 1)
        let refreshed = await eventually { viewModel.arcids == ["current"] && !viewModel.isLoading }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(viewModel.arcids, ["current"])
    }

    func testCancellationStopsLoadAllWithoutApplyingLateResponse() async {
        let loader = ControlledLoadAllPageLoader()
        let viewModel = makeViewModel(loader: loader)
        let profile = makeProfile()

        let loadAll = Task { await viewModel.loadAll(profile: profile) }
        await loader.waitForRequestCount(1)
        loadAll.cancel()
        await loader.succeed(call: 0, arcids: ["late"], recordsFiltered: 2)
        let selected = await loadAll.value
        let requestCount = await loader.requestCount

        XCTAssertEqual(selected, [])
        XCTAssertTrue(viewModel.arcids.isEmpty)
        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(viewModel.errorText)
    }

    private func makeViewModel(loader: ScriptedLoadAllPageLoader) -> LibraryViewModel {
        LibraryViewModel(pageLoader: { _, request in
            try await loader.load(request: request)
        })
    }

    private func makeViewModel(loader: ControlledLoadAllPageLoader) -> LibraryViewModel {
        LibraryViewModel(pageLoader: { _, request in
            try await loader.load(request: request)
        })
    }

    private func makeProfile() -> Profile {
        Profile(
            id: UUID(uuidString: "8842384B-8DE3-44B3-A524-A22A94BDDD2E")!,
            name: "Test",
            baseURL: URL(string: "https://example.test")!,
            language: "en-US"
        )
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

private enum LoadAllTestError: Error, Sendable {
    case failure
}

private actor ScriptedLoadAllPageLoader {
    typealias Request = LibraryViewModel.SearchRequest
    typealias Result = LibraryViewModel.PageLoadResult

    enum Step: Sendable {
        case page(arcids: [String], recordsFiltered: Int)
        case failure
    }

    private var steps: [Step]
    private var requests: [Request] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    var requestCount: Int { requests.count }
    var requestStarts: [Int] { requests.map(\.start) }

    func load(request: Request) throws -> Result {
        requests.append(request)
        guard !steps.isEmpty else { throw LoadAllTestError.failure }

        switch steps.removeFirst() {
        case let .page(arcids, recordsFiltered):
            return Self.result(arcids: arcids, recordsFiltered: recordsFiltered)
        case .failure:
            throw LoadAllTestError.failure
        }
    }

    private static func result(arcids: [String], recordsFiltered: Int) -> Result {
        Result(response: ArchiveSearch(
            data: arcids.map(ArchiveIdOnly.init),
            recordsFiltered: recordsFiltered,
            recordsTotal: recordsFiltered
        ))
    }
}

private actor ControlledLoadAllPageLoader {
    typealias Request = LibraryViewModel.SearchRequest
    typealias Result = LibraryViewModel.PageLoadResult

    private struct PendingRequest {
        let continuation: CheckedContinuation<Result, Error>
    }

    private struct CountWaiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var requests: [Request] = []
    private var pending: [Int: PendingRequest] = [:]
    private var countWaiters: [CountWaiter] = []

    var requestCount: Int { requests.count }

    func load(request: Request) async throws -> Result {
        let call = requests.count
        requests.append(request)
        resumeSatisfiedWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = PendingRequest(continuation: continuation)
        }
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        if requests.count >= expectedCount { return }
        await withCheckedContinuation { continuation in
            countWaiters.append(.init(expectedCount: expectedCount, continuation: continuation))
        }
    }

    func succeed(call: Int, arcids: [String], recordsFiltered: Int) {
        pending.removeValue(forKey: call)?.continuation.resume(
            returning: Result(response: ArchiveSearch(
                data: arcids.map(ArchiveIdOnly.init),
                recordsFiltered: recordsFiltered,
                recordsTotal: recordsFiltered
            ))
        )
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = countWaiters.filter { requests.count >= $0.expectedCount }
        countWaiters.removeAll { requests.count >= $0.expectedCount }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
