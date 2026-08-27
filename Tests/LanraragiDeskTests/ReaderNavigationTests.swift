import XCTest
@testable import LanraragiDesk

final class ReaderNavigationTests: XCTestCase {
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
}
