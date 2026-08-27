import XCTest
@testable import LanraragiDesk

final class ArchiveLoaderInFlightRegistryTests: XCTestCase {
    func testReplacedOperationCannotClearCurrentOwner() {
        var registry = ArchiveLoaderInFlightRegistry<String, Int>()
        let first = registry.insert(Task<Int, Error> { 1 }, for: "archive")
        let replacement = registry.insert(Task<Int, Error> { 2 }, for: "archive")

        XCTAssertFalse(first.task.isCancelled)
        XCTAssertFalse(registry.removeValue(for: "archive", ownedBy: first.id))
        XCTAssertEqual(registry["archive"]?.id, replacement.id)
        XCTAssertTrue(registry.removeValue(for: "archive", ownedBy: replacement.id))
        XCTAssertNil(registry["archive"])
    }

    func testInvalidationCancelsAndRemovesCurrentOwner() {
        var registry = ArchiveLoaderInFlightRegistry<String, Int>()
        let operation = registry.insert(
            Task<Int, Error> {
                try await Task.sleep(for: .seconds(30))
                return 1
            },
            for: "archive"
        )

        registry.cancelAndRemoveValue(for: "archive")

        XCTAssertTrue(operation.task.isCancelled)
        XCTAssertNil(registry["archive"])
        XCTAssertFalse(registry.removeValue(for: "archive", ownedBy: operation.id))
    }

    func testBulkInvalidationCancelsEveryOperation() {
        var registry = ArchiveLoaderInFlightRegistry<String, Int>()
        let first = registry.insert(
            Task<Int, Error> {
                try await Task.sleep(for: .seconds(30))
                return 1
            },
            for: "first"
        )
        let second = registry.insert(
            Task<Int, Error> {
                try await Task.sleep(for: .seconds(30))
                return 2
            },
            for: "second"
        )

        registry.cancelAndRemoveAll()

        XCTAssertTrue(first.task.isCancelled)
        XCTAssertTrue(second.task.isCancelled)
        XCTAssertNil(registry["first"])
        XCTAssertNil(registry["second"])
    }
}
