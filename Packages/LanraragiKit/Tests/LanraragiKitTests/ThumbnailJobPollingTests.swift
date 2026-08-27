import XCTest
@testable import LanraragiKit

final class ThumbnailJobPollingTests: XCTestCase {
    func testMissingStateIsCompleted() {
        XCTAssertEqual(LANraragiClient.thumbnailJobPollDecision(state: nil), .completed)
    }

    func testFinishedStateIsCompletedAndNormalized() {
        XCTAssertEqual(LANraragiClient.thumbnailJobPollDecision(state: "  FINISHED\n"), .completed)
    }

    func testFailedStateIsTerminalAndNormalized() {
        XCTAssertEqual(
            LANraragiClient.thumbnailJobPollDecision(state: "\tFailed "),
            .failed(state: "failed")
        )
    }

    func testQueuedAndRunningStatesRemainPending() {
        XCTAssertEqual(
            LANraragiClient.thumbnailJobPollDecision(state: " QUEUED "),
            .pending(state: "queued")
        )
        XCTAssertEqual(
            LANraragiClient.thumbnailJobPollDecision(state: "Running"),
            .pending(state: "running")
        )
    }

    func testUnknownStateRemainsPendingAndNormalized() {
        XCTAssertEqual(
            LANraragiClient.thumbnailJobPollDecision(state: "  Retrying  "),
            .pending(state: "retrying")
        )
    }

    func testFailedJobThrowsAfterFirstPollWithoutFetching() async {
        let calls = PollCalls(states: ["FAILED"])

        do {
            _ = try await waitForThumbnailJob(calls: calls, maxPolls: 3, fetchResult: .bytes(Data()))
            XCTFail("Expected failed thumbnail job error")
        } catch let LANraragiError.httpStatus(code, body) {
            XCTAssertEqual(code, 500)
            XCTAssertTrue(String(decoding: body ?? Data(), as: UTF8.self).contains("job 42 failed"))
        } catch {
            XCTFail("Expected HTTP 500, got \(error)")
        }

        let counts = await calls.counts()
        XCTAssertEqual(counts.status, 1)
        XCTAssertEqual(counts.fetch, 0)
    }

    func testPollingTimeoutDoesNotPrematurelyFetch() async {
        let calls = PollCalls(states: ["queued", "running"])

        do {
            _ = try await waitForThumbnailJob(calls: calls, maxPolls: 2, fetchResult: .bytes(Data()))
            XCTFail("Expected thumbnail polling timeout")
        } catch let LANraragiError.httpStatus(code, body) {
            XCTAssertEqual(code, 504)
            XCTAssertTrue(String(decoding: body ?? Data(), as: UTF8.self).contains("after 2 polls"))
        } catch {
            XCTFail("Expected HTTP 504, got \(error)")
        }

        let counts = await calls.counts()
        XCTAssertEqual(counts.status, 2)
        XCTAssertEqual(counts.fetch, 0, "A nonterminal job must not trigger a premature follow-up fetch")
    }

    func testCompletedJobFetchesThumbnailOnce() async throws {
        let expected = Data([0x01, 0x02, 0x03])
        let calls = PollCalls(states: ["finished"])

        let result = try await waitForThumbnailJob(
            calls: calls,
            maxPolls: 3,
            fetchResult: .bytes(expected)
        )

        XCTAssertEqual(result, expected)
        let counts = await calls.counts()
        XCTAssertEqual(counts.status, 1)
        XCTAssertEqual(counts.fetch, 1)
    }

    func testCompletedJobReturningAnotherJobIsInvalidResponse() async {
        let calls = PollCalls(states: [nil])

        do {
            _ = try await waitForThumbnailJob(
                calls: calls,
                maxPolls: 3,
                fetchResult: .job(MinionJob(job: 43))
            )
            XCTFail("Expected invalid response")
        } catch LANraragiError.invalidResponse {
            // Expected.
        } catch {
            XCTFail("Expected invalid response, got \(error)")
        }

        let counts = await calls.counts()
        XCTAssertEqual(counts.status, 1)
        XCTAssertEqual(counts.fetch, 1)
    }

    private func waitForThumbnailJob(
        calls: PollCalls,
        maxPolls: Int,
        fetchResult: ThumbnailResponse
    ) async throws -> Data {
        try await LANraragiClient.waitForThumbnailJob(
            jobID: 42,
            pollInterval: .zero,
            maxPolls: maxPolls,
            status: { await calls.nextState() },
            fetchThumbnail: {
                await calls.recordFetch()
                return fetchResult
            }
        )
    }
}

private actor PollCalls {
    private var states: [String?]
    private var statusCount = 0
    private var fetchCount = 0

    init(states: [String?]) {
        self.states = states
    }

    func nextState() -> String? {
        statusCount += 1
        return states.isEmpty ? "running" : states.removeFirst()
    }

    func recordFetch() {
        fetchCount += 1
    }

    func counts() -> (status: Int, fetch: Int) {
        (statusCount, fetchCount)
    }
}
