import Foundation
import XCTest
@testable import LanraragiKit

final class NotDuplicateTimestampTests: XCTestCase {
    func testConflictKeepsStoredTimestampAndNewestFirstOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanraragiKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try IndexStore(configuration: .init(
            url: directory.appendingPathComponent("index.sqlite")
        ))
        let profileID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        let original = try store.addNotDuplicatePair(
            profileID: profileID,
            arcidA: "beta",
            arcidB: "alpha",
            createdAt: 1_000
        )
        XCTAssertEqual(original.arcidA, "alpha")
        XCTAssertEqual(original.arcidB, "beta")
        XCTAssertEqual(original.createdAt, 1_000)

        let existing = try store.addNotDuplicatePair(
            profileID: profileID,
            arcidA: "alpha",
            arcidB: "beta",
            createdAt: 9_000
        )
        XCTAssertEqual(existing.createdAt, 1_000)

        _ = try store.addNotDuplicatePair(
            profileID: profileID,
            arcidA: "charlie",
            arcidB: "delta",
            createdAt: 3_000
        )
        _ = try store.addNotDuplicatePair(
            profileID: profileID,
            arcidA: "charlie",
            arcidB: "echo",
            createdAt: 3_000
        )

        let loaded = try store.loadNotDuplicatePairsNewestFirst(profileID: profileID)
        XCTAssertEqual(loaded.map(\.createdAt), [3_000, 3_000, 1_000])
        XCTAssertEqual(loaded.map { "\($0.arcidA)|\($0.arcidB)" }, [
            "charlie|delta",
            "charlie|echo",
            "alpha|beta",
        ])
    }
}
