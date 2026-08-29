import XCTest
@testable import LanraragiDesk

final class ReaderNavigationTests: XCTestCase {
    func testInitialIndexUsesFirstPageOrAlignedLastSpread() {
        XCTAssertEqual(
            ReaderNavigation.initialIndex(
                pageCount: 4,
                twoPageSpread: false,
                startAtLastPage: false
            ),
            0
        )
        XCTAssertEqual(
            ReaderNavigation.initialIndex(
                pageCount: 4,
                twoPageSpread: false,
                startAtLastPage: true
            ),
            3
        )
        XCTAssertEqual(
            ReaderNavigation.initialIndex(
                pageCount: 4,
                twoPageSpread: true,
                startAtLastPage: true
            ),
            2
        )
        XCTAssertEqual(
            ReaderNavigation.initialIndex(
                pageCount: 5,
                twoPageSpread: true,
                startAtLastPage: true
            ),
            4
        )
        XCTAssertEqual(
            ReaderNavigation.initialIndex(
                pageCount: 0,
                twoPageSpread: true,
                startAtLastPage: true
            ),
            0
        )
    }

    func testEvenPageSpreadsStopAtLastAlignedSpread() {
        XCTAssertEqual(
            ReaderNavigation.advance(from: 0, pageCount: 4, twoPageSpread: true),
            .page(2)
        )
        XCTAssertEqual(
            ReaderNavigation.advance(from: 2, pageCount: 4, twoPageSpread: true),
            .endOfArchive
        )
    }

    func testOddPageSpreadsReachTrailingSingletonOnce() {
        XCTAssertEqual(
            ReaderNavigation.advance(from: 2, pageCount: 5, twoPageSpread: true),
            .page(4)
        )
        XCTAssertEqual(
            ReaderNavigation.advance(from: 4, pageCount: 5, twoPageSpread: true),
            .endOfArchive
        )
    }

    func testSpreadRetreatMovesBetweenAlignedStarts() {
        XCTAssertEqual(
            ReaderNavigation.retreat(from: 4, pageCount: 5, twoPageSpread: true),
            .page(2)
        )
        XCTAssertEqual(
            ReaderNavigation.retreat(from: 2, pageCount: 4, twoPageSpread: true),
            .page(0)
        )
    }

    func testSinglePageModeKeepsOnePageSteps() {
        XCTAssertEqual(
            ReaderNavigation.advance(from: 1, pageCount: 4, twoPageSpread: false),
            .page(2)
        )
        XCTAssertEqual(
            ReaderNavigation.retreat(from: 2, pageCount: 4, twoPageSpread: false),
            .page(1)
        )
    }

    func testEveryForwardInputUsesTheSameSpreadDecision() {
        let inputs: [ReaderNavigationInput] = [
            .toolbarRight,
            .keyboardRight,
            .moveRight,
            .clickRight,
            .space(shifted: false),
            .autoAdvance,
        ]

        for input in inputs {
            XCTAssertEqual(
                ReaderNavigation.decision(
                    for: input,
                    from: 2,
                    pageCount: 4,
                    twoPageSpread: true,
                    rightToLeft: false
                ),
                .endOfArchive,
                "Unexpected decision for \(input)"
            )
        }
    }

    func testPhysicalInputsReverseInRightToLeftMode() {
        XCTAssertEqual(
            ReaderNavigation.decision(
                for: .toolbarLeft,
                from: 0,
                pageCount: 4,
                twoPageSpread: true,
                rightToLeft: true
            ),
            .page(2)
        )
        XCTAssertEqual(
            ReaderNavigation.decision(
                for: .clickRight,
                from: 2,
                pageCount: 4,
                twoPageSpread: true,
                rightToLeft: true
            ),
            .page(0)
        )
    }

    func testSidebarSelectionNormalizesOnlyInSpreadMode() {
        XCTAssertEqual(
            ReaderNavigation.normalizedIndex(3, pageCount: 6, twoPageSpread: true),
            2
        )
        XCTAssertEqual(
            ReaderNavigation.normalizedIndex(3, pageCount: 6, twoPageSpread: false),
            3
        )
    }

    func testLastSidebarSelectionForEvenCountReturnsFinalFullSpread() {
        XCTAssertEqual(
            ReaderNavigation.normalizedIndex(3, pageCount: 4, twoPageSpread: true),
            2
        )
    }

    func testSelectionIsClampedToArchiveBounds() {
        XCTAssertEqual(
            ReaderNavigation.normalizedIndex(-10, pageCount: 4, twoPageSpread: false),
            0
        )
        XCTAssertEqual(
            ReaderNavigation.normalizedIndex(10, pageCount: 5, twoPageSpread: true),
            4
        )
        XCTAssertEqual(
            ReaderNavigation.normalizedIndex(10, pageCount: 4, twoPageSpread: true),
            2
        )
        XCTAssertEqual(
            ReaderNavigation.normalizedIndex(10, pageCount: 0, twoPageSpread: true),
            0
        )
    }

    func testFirstAndLastPageReportArchiveBoundaries() {
        XCTAssertEqual(
            ReaderNavigation.retreat(from: 0, pageCount: 4, twoPageSpread: false),
            .startOfArchive
        )
        XCTAssertEqual(
            ReaderNavigation.advance(from: 3, pageCount: 4, twoPageSpread: false),
            .endOfArchive
        )
    }

    func testEmptyArchiveReportsDirectionalBoundaries() {
        XCTAssertEqual(
            ReaderNavigation.advance(from: 0, pageCount: 0, twoPageSpread: true),
            .endOfArchive
        )
        XCTAssertEqual(
            ReaderNavigation.retreat(from: 0, pageCount: 0, twoPageSpread: true),
            .startOfArchive
        )
    }

    func testNonAlignedCurrentSpreadStillMakesAlignedDecisions() {
        XCTAssertEqual(
            ReaderNavigation.advance(from: 3, pageCount: 6, twoPageSpread: true),
            .page(4)
        )
        XCTAssertEqual(
            ReaderNavigation.retreat(from: 3, pageCount: 6, twoPageSpread: true),
            .page(0)
        )
    }

    func testNonAlignedFinalIndexForEvenCountUsesAlignedBoundaries() {
        XCTAssertEqual(
            ReaderNavigation.advance(from: 3, pageCount: 4, twoPageSpread: true),
            .endOfArchive
        )
        XCTAssertEqual(
            ReaderNavigation.retreat(from: 3, pageCount: 4, twoPageSpread: true),
            .page(0)
        )
    }

    func testBoundaryDecisionsLeaveTankoubonTransitionsUnambiguous() {
        let forward = ReaderNavigation.advance(from: 2, pageCount: 4, twoPageSpread: true)
        let backward = ReaderNavigation.retreat(from: 0, pageCount: 4, twoPageSpread: true)

        XCTAssertEqual(forward, .endOfArchive)
        XCTAssertEqual(backward, .startOfArchive)
    }

    func testForwardBoundaryOpensNextTankArchiveAtFirstPage() throws {
        let route = try tankRoute(startingAt: "b")
        let expected = try tankRoute(startingAt: "c")

        XCTAssertEqual(
            destination(
                input: .toolbarRight,
                index: 2,
                route: route
            ),
            .archive(expected)
        )
    }

    func testBackwardBoundaryOpensPreviousTankArchiveAtLastPage() throws {
        let route = try tankRoute(startingAt: "b")
        var expected = try tankRoute(startingAt: "a")
        expected.startAtLastPage = true

        XCTAssertEqual(
            destination(
                input: .toolbarLeft,
                index: 0,
                route: route
            ),
            .archive(expected)
        )
    }

    func testPhysicalBoundaryNavigationRespectsRightToLeftDirection() throws {
        let route = try tankRoute(startingAt: "b")
        let next = try tankRoute(startingAt: "c")
        var previous = try tankRoute(startingAt: "a")
        previous.startAtLastPage = true

        XCTAssertEqual(
            destination(
                input: .toolbarLeft,
                index: 2,
                route: route,
                rightToLeft: true
            ),
            .archive(next)
        )
        XCTAssertEqual(
            destination(
                input: .toolbarRight,
                index: 0,
                route: route,
                rightToLeft: true
            ),
            .archive(previous)
        )
    }

    func testSpaceAndShiftSpaceCrossExpectedTankBoundaries() throws {
        let route = try tankRoute(startingAt: "b")
        let next = try tankRoute(startingAt: "c")
        var previous = try tankRoute(startingAt: "a")
        previous.startAtLastPage = true

        XCTAssertEqual(
            destination(input: .space(shifted: false), index: 2, route: route),
            .archive(next)
        )
        XCTAssertEqual(
            destination(input: .space(shifted: true), index: 0, route: route),
            .archive(previous)
        )
    }

    func testTankAndPlainArchiveOuterBoundariesStayPut() throws {
        let first = try tankRoute(startingAt: "a")
        let last = try tankRoute(startingAt: "c")
        let plain = ReaderRoute(profileID: first.profileID, arcid: "plain")

        XCTAssertEqual(
            destination(input: .toolbarLeft, index: 0, route: first),
            .boundary
        )
        XCTAssertEqual(
            destination(input: .toolbarRight, index: 2, route: last),
            .boundary
        )
        XCTAssertEqual(
            destination(input: .toolbarRight, index: 2, route: plain),
            .boundary
        )
    }

    func testAutoAdvanceStopsAtTankArchiveBoundary() throws {
        let route = try tankRoute(startingAt: "b")

        XCTAssertEqual(
            destination(
                input: .autoAdvance,
                index: 2,
                route: route,
                userInitiated: false
            ),
            .boundary
        )
    }

    func testOnlyAutomaticBoundaryStopsAutoAdvance() {
        XCTAssertTrue(
            ReaderNavigation.shouldStopAutoAdvance(
                at: .boundary,
                userInitiated: false
            )
        )
        XCTAssertFalse(
            ReaderNavigation.shouldStopAutoAdvance(
                at: .boundary,
                userInitiated: true
            )
        )
        XCTAssertFalse(
            ReaderNavigation.shouldStopAutoAdvance(
                at: .page(1),
                userInitiated: false
            )
        )
    }

    func testRightToLeftSpaceKeysKeepLogicalTankDirection() throws {
        let route = try tankRoute(startingAt: "b")
        let next = try tankRoute(startingAt: "c")
        var previous = try tankRoute(startingAt: "a")
        previous.startAtLastPage = true

        XCTAssertEqual(
            destination(
                input: .space(shifted: false),
                index: 2,
                route: route,
                rightToLeft: true
            ),
            .archive(next)
        )
        XCTAssertEqual(
            destination(
                input: .space(shifted: true),
                index: 0,
                route: route,
                rightToLeft: true
            ),
            .archive(previous)
        )
    }

    private func tankRoute(startingAt arcid: String) throws -> ReaderRoute {
        let context = TankoubonReaderContext(
            tankID: "TANK_1",
            name: "Volume 1",
            archives: ["a", "b", "c"]
        )
        let profileID = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        return try XCTUnwrap(context.readerRoute(
            profileID: profileID,
            startingAt: arcid
        ))
    }

    private func destination(
        input: ReaderNavigationInput,
        index: Int,
        route: ReaderRoute,
        rightToLeft: Bool = false,
        userInitiated: Bool = true
    ) -> ReaderNavigationDestination {
        ReaderNavigation.destination(
            for: input,
            from: index,
            pageCount: 4,
            twoPageSpread: true,
            rightToLeft: rightToLeft,
            route: route,
            userInitiated: userInitiated
        )
    }
}
