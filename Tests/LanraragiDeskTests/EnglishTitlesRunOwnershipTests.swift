import Foundation
import XCTest
@testable import LanraragiDesk

final class EnglishTitlesRunOwnershipTests: XCTestCase {
    func testCancellationKeepsRunBusyAndBlocksRestartUntilFinish() throws {
        var ownership = EnglishTitlesRunOwnership()
        let firstID = UUID()
        let first = try XCTUnwrap(ownership.begin(id: firstID))

        XCTAssertTrue(ownership.requestCancellation(of: first))
        XCTAssertTrue(ownership.isBusy)
        XCTAssertTrue(ownership.owns(first))
        XCTAssertFalse(ownership.acceptsUpdates(from: first))
        XCTAssertNil(ownership.begin(id: UUID()))

        XCTAssertTrue(ownership.finish(first))
        XCTAssertFalse(ownership.isBusy)
        XCTAssertFalse(ownership.isCancellationRequested)
        XCTAssertNotNil(ownership.begin(id: UUID()))
    }

    func testStaleCleanupCannotClearNewerRun() throws {
        var ownership = EnglishTitlesRunOwnership()
        let first = try XCTUnwrap(ownership.begin(id: UUID()))
        XCTAssertTrue(ownership.finish(first))

        let second = try XCTUnwrap(ownership.begin(id: UUID()))

        XCTAssertFalse(ownership.finish(first))
        XCTAssertTrue(ownership.isBusy)
        XCTAssertTrue(ownership.owns(second))
        XCTAssertTrue(ownership.acceptsUpdates(from: second))
    }

    func testOnlyCurrentRunCanRequestCancellation() throws {
        var ownership = EnglishTitlesRunOwnership()
        let first = try XCTUnwrap(ownership.begin(id: UUID()))
        XCTAssertTrue(ownership.finish(first))
        let second = try XCTUnwrap(ownership.begin(id: UUID()))

        XCTAssertFalse(ownership.requestCancellation(of: first))
        XCTAssertFalse(ownership.isCancellationRequested)
        XCTAssertTrue(ownership.requestCancellation(of: second))
        XCTAssertFalse(ownership.requestCancellation(of: second))
    }
}
