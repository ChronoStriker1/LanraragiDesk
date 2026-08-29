import Foundation
import XCTest
@testable import LanraragiDesk

final class ReaderRouteTests: XCTestCase {
    func testTankoubonReadOwnershipCoalescesAndRejectsStaleRequests() throws {
        var ownership = TankoubonReadOwnership()
        let first = try XCTUnwrap(ownership.begin(tankID: " TANK_1 "))

        XCTAssertEqual(first.tankID, "TANK_1")
        XCTAssertNil(ownership.begin(tankID: "TANK_1"))
        XCTAssertTrue(ownership.isCurrent(first))

        let replacement = try XCTUnwrap(ownership.begin(tankID: "TANK_2"))
        XCTAssertFalse(ownership.isCurrent(first))
        XCTAssertFalse(ownership.finishIfCurrent(first))
        XCTAssertTrue(ownership.isCurrent(replacement))
        XCTAssertTrue(ownership.finishIfCurrent(replacement))
        XCTAssertFalse(ownership.isCurrent(replacement))
    }

    func testTankContextFindsAdjacentArchivesInServerOrder() {
        let context = makeContext(archives: ["a", "b", "c"])

        XCTAssertEqual(context.index(of: "b"), 1)
        XCTAssertEqual(context.archiveBefore("b"), "a")
        XCTAssertEqual(context.archiveAfter("b"), "c")
    }

    func testTankContextHasNoNeighborAtBoundariesOrForMissingArchive() {
        let context = makeContext(archives: ["a", "b", "c"])

        XCTAssertNil(context.archiveBefore("a"))
        XCTAssertNil(context.archiveAfter("c"))
        XCTAssertNil(context.archiveBefore("missing"))
        XCTAssertNil(context.archiveAfter("missing"))
    }

    func testTankContextNormalizesBlankAndDuplicateArchiveIDs() {
        let context = TankoubonReaderContext(
            tankID: " TANK_1 ",
            name: " Volume 1 ",
            archives: ["a", " a ", "", "b", "b", "c"],
            archiveTitles: ["a": " First ", "missing": "Unused", "b": "  "]
        )

        XCTAssertEqual(context.tankID, "TANK_1")
        XCTAssertEqual(context.name, "Volume 1")
        XCTAssertEqual(context.archives, ["a", "b", "c"])
        XCTAssertEqual(context.archiveTitles, ["a": "First"])
        XCTAssertEqual(context.archiveAfter("a"), "b")
        XCTAssertEqual(context.displayTitle(for: "a", position: 1), "First")
        XCTAssertEqual(context.displayTitle(for: "b", position: 2), "Archive 2")
    }

    func testReaderRouteFactoryUsesFirstArchiveAndRejectsInvalidSelections() throws {
        let profileID = UUID()
        let context = makeContext(archives: ["a", "b"])

        let first = try XCTUnwrap(context.readerRoute(profileID: profileID))
        XCTAssertEqual(first.arcid, "a")
        XCTAssertEqual(first.profileID, profileID)
        XCTAssertEqual(first.tank, context)
        XCTAssertFalse(first.startAtLastPage)

        let selected = try XCTUnwrap(context.readerRoute(
            profileID: profileID,
            startingAt: "b",
            startAtLastPage: true
        ))
        XCTAssertEqual(selected.arcid, "b")
        XCTAssertTrue(selected.startAtLastPage)

        XCTAssertNil(context.readerRoute(profileID: profileID, startingAt: "missing"))
        XCTAssertNil(makeContext(archives: []).readerRoute(profileID: profileID))
    }

    func testReaderRouteRoundTripsTankContextAndLastPageFlag() throws {
        let route = try XCTUnwrap(
            makeContext(archives: ["a", "b"]).readerRoute(
                profileID: UUID(),
                startingAt: "b",
                startAtLastPage: true
            )
        )

        let data = try JSONEncoder().encode(route)
        let decoded = try JSONDecoder().decode(ReaderRoute.self, from: data)

        XCTAssertEqual(decoded, route)
    }

    func testReaderRouteDecodesLegacyPayloadWithDefaults() throws {
        let profileID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "profileID": profileID.uuidString,
            "arcid": "legacy-archive",
        ])

        let route = try JSONDecoder().decode(ReaderRoute.self, from: data)

        XCTAssertEqual(route.profileID, profileID)
        XCTAssertEqual(route.arcid, "legacy-archive")
        XCTAssertNil(route.tank)
        XCTAssertFalse(route.startAtLastPage)
    }

    func testTankContextDecodesLegacyPayloadWithoutArchiveTitles() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "tankID": "TANK_1",
            "name": "Volume 1",
            "archives": ["a", "b"],
        ])

        let context = try JSONDecoder().decode(TankoubonReaderContext.self, from: data)

        XCTAssertEqual(context.archiveTitles, [:])
        XCTAssertEqual(context.displayTitle(for: "b", position: 2), "Archive 2")
    }

    func testPlainArchiveRouteDefaultsToFirstPageWithoutTankContext() {
        let route = ReaderRoute(profileID: UUID(), arcid: "archive")

        XCTAssertNil(route.tank)
        XCTAssertFalse(route.startAtLastPage)
    }

    private func makeContext(archives: [String]) -> TankoubonReaderContext {
        TankoubonReaderContext(
            tankID: "TANK_1",
            name: "Volume 1",
            archives: archives
        )
    }
}
