import Foundation
import XCTest
@testable import LanraragiDesk

final class BatchPreviewWorkflowTests: XCTestCase {
    func testPreviewSettingSelectsExpectedStartAction() {
        XCTAssertEqual(BatchPreviewWorkflow.startAction(previewEnabled: true), .previewThenQueue)
        XCTAssertEqual(BatchPreviewWorkflow.startAction(previewEnabled: false), .queueImmediately)
    }

    func testSuccessfulPreviewThenQueueQueuesExactlyOnce() throws {
        var workflow = BatchPreviewWorkflow()
        let run = try XCTUnwrap(workflow.begin(intent: .previewThenQueue, id: UUID()))

        XCTAssertEqual(workflow.complete(run, outcome: .succeeded), .queueBatch)
        XCTAssertEqual(workflow.complete(run, outcome: .succeeded), .ignored)
        XCTAssertNil(workflow.activeRun)
    }

    func testPreviewOnlyNeverQueues() throws {
        var workflow = BatchPreviewWorkflow()
        let run = try XCTUnwrap(workflow.begin(intent: .previewOnly, id: UUID()))

        XCTAssertEqual(workflow.complete(run, outcome: .succeeded), .previewOnly)
    }

    func testFailedPreviewDoesNotQueue() throws {
        var workflow = BatchPreviewWorkflow()
        let run = try XCTUnwrap(workflow.begin(intent: .previewThenQueue, id: UUID()))

        XCTAssertEqual(workflow.complete(run, outcome: .failed), .failed)
        XCTAssertNil(workflow.activeRun)
    }

    func testCancellationStaysOwnedUntilTaskFinishesAndDoesNotQueue() throws {
        var workflow = BatchPreviewWorkflow()
        let run = try XCTUnwrap(workflow.begin(intent: .previewThenQueue, id: UUID()))

        XCTAssertTrue(workflow.requestCancellation())
        XCTAssertTrue(workflow.owns(run))
        XCTAssertFalse(workflow.acceptsUpdates(from: run))
        XCTAssertNil(workflow.begin(intent: .previewThenQueue, id: UUID()))
        XCTAssertEqual(workflow.complete(run, outcome: .succeeded), .cancelled)
        XCTAssertNil(workflow.activeRun)
    }

    func testTaskCancellationDoesNotQueueWithoutExplicitRequest() throws {
        var workflow = BatchPreviewWorkflow()
        let run = try XCTUnwrap(workflow.begin(intent: .previewThenQueue, id: UUID()))

        XCTAssertEqual(workflow.complete(run, outcome: .cancelled), .cancelled)
    }
}
