import Foundation
import AppKit
import LanraragiKit
import SwiftUI
import XCTest
@testable import LanraragiDesk

@MainActor
final class LibraryViewModelGenerationTests: XCTestCase {
    func testSearchButtonReadsRetainedControlAfterFieldEditorResigns() {
        let visibleDraft = "codex-regression-20260827-fixture"
        let textField = NSTextField(string: visibleDraft)
        let control = LibrarySearchFieldControl()
        control.attach(textField)

        XCTAssertNil(textField.currentEditor())
        XCTAssertEqual(control.currentText(fallback: ""), visibleDraft)
    }

    func testSearchControlFallsBackOnlyAfterUnderlyingFieldIsReleased() {
        let fallback = "bound-query"
        let textField = NSTextField(string: "visible-query")
        let control = LibrarySearchFieldControl()
        control.attach(textField)
        control.detach(textField)

        XCTAssertEqual(control.currentText(fallback: fallback), fallback)
    }

    func testSearchReturnCommandSubmitsLiveFieldEditorValue() {
        let visibleDraft = "artist:codex-regression-20260827"
        var boundDraft = ""
        var submittedDraft: String?
        let control = LibrarySearchFieldControl()
        let coordinator = LibrarySearchTextField.Coordinator(
            text: Binding(
                get: { boundDraft },
                set: { boundDraft = $0 }
            ),
            control: control,
            onSubmit: { submittedDraft = $0 }
        )
        let textField = NSTextField(string: "")
        let fieldEditor = NSTextView(frame: .zero)
        fieldEditor.string = visibleDraft

        let handled = coordinator.control(
            textField,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(textField.stringValue, visibleDraft)
        XCTAssertEqual(boundDraft, visibleDraft)
        XCTAssertEqual(submittedDraft, visibleDraft)
    }

    func testReturnSearchSupersedesInflightBlankSubmission() async throws {
        let loader = ControlledLibraryPageLoader()
        let viewModel = makeViewModel(loader: loader)
        let profile = makeProfile()

        viewModel.submitSearch(query: "", profile: profile)
        await loader.waitForRequestCount(1)
        let storedBlankRequest = await loader.request(at: 0)
        let blankRequest = try XCTUnwrap(storedBlankRequest)
        XCTAssertEqual(blankRequest.query, "")

        let query = "artist:codex-regression-20260827"
        viewModel.submitSearch(query: query, profile: profile)
        await loader.waitForRequestCount(2)

        let storedSubmittedRequest = await loader.request(at: 1)
        let submittedRequest = try XCTUnwrap(storedSubmittedRequest)
        XCTAssertEqual(submittedRequest.start, 0)
        XCTAssertEqual(submittedRequest.query, query)

        await loader.succeed(call: 0, arcids: (0..<25).map { "stale-\($0)" }, recordsFiltered: 25)
        let staleLoadFinished = await eventually {
            viewModel.requestTimingHistory.entries.contains { $0.outcome == .superseded }
        }
        XCTAssertTrue(staleLoadFinished)
        XCTAssertTrue(viewModel.arcids.isEmpty)

        let fixtureIDs = ["fixture-a", "fixture-b"]
        await loader.succeed(call: 1, arcids: fixtureIDs, recordsFiltered: fixtureIDs.count)
        let submittedLoadFinished = await eventually {
            viewModel.arcids == fixtureIDs && !viewModel.isLoading
        }

        XCTAssertTrue(submittedLoadFinished)
        XCTAssertEqual(viewModel.query, query)
        XCTAssertEqual(viewModel.arcids, fixtureIDs)
    }

    func testRefreshStartsNewGenerationAndStaleSuccessCannotMutateItsState() async throws {
        let loader = ControlledLibraryPageLoader()
        let viewModel = makeViewModel(loader: loader)
        let profile = makeProfile()

        viewModel.query = "old query"
        let staleLoad = Task { await viewModel.loadMore(profile: profile) }
        await loader.waitForRequestCount(1)

        viewModel.query = "new query"
        viewModel.categoryID = "new-category"
        viewModel.newOnly = true
        viewModel.untaggedOnly = true
        viewModel.sort = .newestAdded
        viewModel.groupTanks = false
        viewModel.refresh(profile: profile)

        // The new generation must not coalesce behind the still-pending old request.
        await loader.waitForRequestCount(2)
        XCTAssertTrue(viewModel.isLoading)

        let storedFirstRequest = await loader.request(at: 0)
        let firstRequest = try XCTUnwrap(storedFirstRequest)
        XCTAssertEqual(firstRequest.start, 0)
        XCTAssertEqual(firstRequest.query, "old query")

        let storedRefreshedRequest = await loader.request(at: 1)
        let refreshedRequest = try XCTUnwrap(storedRefreshedRequest)
        XCTAssertEqual(
            refreshedRequest,
            .init(
                start: 0,
                query: "new query",
                categoryID: "new-category",
                newOnly: true,
                untaggedOnly: true,
                sort: .newestAdded,
                groupTanks: false,
                knownDateAddedSortSupport: nil
            )
        )

        await loader.succeed(call: 1, arcids: ["new-1"], recordsFiltered: 3)
        let refreshedLoadFinished = await eventually {
            viewModel.arcids == ["new-1"] && !viewModel.isLoading
        }
        XCTAssertTrue(refreshedLoadFinished)

        // This old result would previously append stale IDs, advance `start`, and
        // overwrite the current generation's sort capability/banner.
        await loader.succeed(
            call: 0,
            arcids: ["old-1", "old-2"],
            recordsFiltered: 50,
            dateAddedSortSupport: false,
            fellBackToTitle: true
        )
        _ = await staleLoad.value

        XCTAssertEqual(viewModel.arcids, ["new-1"])
        XCTAssertEqual(viewModel.sort, .newestAdded)
        XCTAssertNil(viewModel.bannerText)
        XCTAssertNil(viewModel.errorText)
        XCTAssertFalse(viewModel.isLoading)

        // Changing live controls without beginning another refresh must not let an
        // await mix those values into pagination for the current generation.
        viewModel.query = "uncommitted query"
        viewModel.categoryID = "other-category"
        viewModel.newOnly = false
        viewModel.untaggedOnly = false
        viewModel.sort = .title
        viewModel.groupTanks = true

        let firstScrollLoad = Task { await viewModel.loadMore(profile: profile) }
        let coalescedScrollLoad = Task { await viewModel.loadMore(profile: profile) }
        await loader.waitForRequestCount(3)
        await Task.yield()
        let requestCount = await loader.requestCount
        XCTAssertEqual(requestCount, 3)

        let storedPaginationRequest = await loader.request(at: 2)
        let paginationRequest = try XCTUnwrap(storedPaginationRequest)
        XCTAssertEqual(paginationRequest.start, 1)
        XCTAssertEqual(paginationRequest.query, "new query")
        XCTAssertEqual(paginationRequest.categoryID, "new-category")
        XCTAssertTrue(paginationRequest.newOnly)
        XCTAssertTrue(paginationRequest.untaggedOnly)
        XCTAssertEqual(paginationRequest.sort, .newestAdded)
        XCTAssertFalse(paginationRequest.groupTanks)

        await loader.succeed(call: 2, arcids: ["new-2", "new-3"], recordsFiltered: 3)
        _ = await firstScrollLoad.value
        _ = await coalescedScrollLoad.value
        XCTAssertEqual(viewModel.arcids, ["new-1", "new-2", "new-3"])
    }

    func testStaleFailureAndCleanupCannotUnbusyCurrentGeneration() async throws {
        let loader = ControlledLibraryPageLoader()
        let viewModel = makeViewModel(loader: loader)
        let profile = makeProfile()

        viewModel.query = "old query"
        let staleLoad = Task { await viewModel.loadMore(profile: profile) }
        await loader.waitForRequestCount(1)

        viewModel.query = "new query"
        viewModel.refresh(profile: profile)
        await loader.waitForRequestCount(2)

        await loader.fail(call: 0, error: TestLoadError.staleFailure)
        _ = await staleLoad.value

        XCTAssertTrue(viewModel.isLoading, "Stale defer must not clear the current load's busy state")
        XCTAssertNil(viewModel.errorText, "A stale failure must not become the current generation's error")
        XCTAssertTrue(viewModel.arcids.isEmpty)

        await loader.succeed(call: 1, arcids: ["current"], recordsFiltered: 1)
        let currentLoadFinished = await eventually {
            viewModel.arcids == ["current"] && !viewModel.isLoading
        }
        XCTAssertTrue(currentLoadFinished)
        XCTAssertNil(viewModel.errorText)
    }

    func testLoadMoreForDifferentProfileStartsAtZeroAndReplacesResults() async throws {
        let loader = ControlledLibraryPageLoader()
        let viewModel = makeViewModel(loader: loader)
        let firstProfile = makeProfile()
        let secondProfile = Profile(
            id: UUID(uuidString: "9EC26B84-4587-4D1C-9A81-C55AE41ED539")!,
            name: "Second",
            baseURL: URL(string: "https://second.example.test")!,
            language: "ja-JP"
        )

        viewModel.query = "first profile"
        let firstLoad = Task { await viewModel.loadMore(profile: firstProfile) }
        await loader.waitForRequestCount(1)
        await loader.succeed(call: 0, arcids: ["first-1"], recordsFiltered: 3)
        _ = await firstLoad.value
        XCTAssertEqual(viewModel.arcids, ["first-1"])

        viewModel.query = "second profile"
        viewModel.categoryID = "second-category"
        viewModel.newOnly = true
        viewModel.groupTanks = false
        let secondLoad = Task { await viewModel.loadMore(profile: secondProfile) }
        await loader.waitForRequestCount(2)

        XCTAssertTrue(viewModel.arcids.isEmpty)
        let storedRequest = await loader.request(at: 1)
        let request = try XCTUnwrap(storedRequest)
        XCTAssertEqual(request.start, 0)
        XCTAssertEqual(request.query, "second profile")
        XCTAssertEqual(request.categoryID, "second-category")
        XCTAssertTrue(request.newOnly)
        XCTAssertFalse(request.groupTanks)
        XCTAssertNil(request.knownDateAddedSortSupport)

        await loader.succeed(call: 1, arcids: ["second-1"], recordsFiltered: 1)
        _ = await secondLoad.value
        XCTAssertEqual(viewModel.arcids, ["second-1"])
    }

    private func makeViewModel(loader: ControlledLibraryPageLoader) -> LibraryViewModel {
        LibraryViewModel(pageLoader: { _, request in
            try await loader.load(request: request)
        })
    }

    private func makeProfile() -> Profile {
        Profile(
            id: UUID(uuidString: "ED43FC8F-C5B4-445F-A29B-A46D0F9B7CA7")!,
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

private enum TestLoadError: Error, Sendable {
    case staleFailure
}

private actor ControlledLibraryPageLoader {
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

    func request(at index: Int) -> Request? {
        guard requests.indices.contains(index) else { return nil }
        return requests[index]
    }

    func succeed(
        call: Int,
        arcids: [String],
        recordsFiltered: Int,
        dateAddedSortSupport: Bool? = nil,
        fellBackToTitle: Bool = false
    ) {
        let response = ArchiveSearch(
            data: arcids.map(ArchiveIdOnly.init),
            recordsFiltered: recordsFiltered,
            recordsTotal: recordsFiltered
        )
        pending.removeValue(forKey: call)?.continuation.resume(
            returning: Result(
                response: response,
                dateAddedSortSupport: dateAddedSortSupport,
                fellBackToTitle: fellBackToTitle
            )
        )
    }

    func fail(call: Int, error: TestLoadError) {
        pending.removeValue(forKey: call)?.continuation.resume(throwing: error)
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = countWaiters.filter { requests.count >= $0.expectedCount }
        countWaiters.removeAll { requests.count >= $0.expectedCount }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
