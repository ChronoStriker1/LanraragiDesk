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
}
