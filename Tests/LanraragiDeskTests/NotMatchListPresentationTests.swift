import XCTest
import LanraragiKit
@testable import LanraragiDesk

@MainActor
final class NotMatchListPresentationTests: XCTestCase {
    private let pairs = [
        IndexStore.NotDuplicatePair(arcidA: "alpha-10", arcidB: "zeta-30", createdAt: 1_725_228_000_000),
        IndexStore.NotDuplicatePair(arcidA: "beta-20", arcidB: "delta-10", createdAt: 1_725_314_400_000),
        IndexStore.NotDuplicatePair(arcidA: "alpha-20", arcidB: "gamma-20", createdAt: 1_725_314_400_000)
    ]

    func testFiltersByEitherArchiveIDUsingAllSearchTokens() {
        let leftMatches = results(query: "alpha")
        XCTAssertEqual(leftMatches.map(\.arcidA), ["alpha-20", "alpha-10"])

        let rightMatches = results(query: "delta-10")
        XCTAssertEqual(rightMatches.map(\.arcidA), ["beta-20"])

        let tokenMatch = results(query: "alpha, gamma")
        XCTAssertEqual(tokenMatch.map(\.arcidA), ["alpha-20"])
    }

    func testFiltersByVisibleCreatedTextAndRawTimestamp() {
        let pair = pairs[0]
        let visibleText = NotMatchListPresentation.createdText(for: pair)
        let isoDate = String(
            ISO8601DateFormatter()
                .string(from: NotMatchListPresentation.createdDate(for: pair))
                .prefix(10)
        )

        XCTAssertEqual(results(query: visibleText), [pair])
        XCTAssertEqual(results(query: String(pair.createdAt)), [pair])
        XCTAssertEqual(results(query: isoDate), [pair])
    }

    func testFullFieldMatchTakesPrecedenceOverTokensAcrossUnrelatedFields() {
        let target = pairs[0]
        let query = NotMatchListPresentation.createdText(for: target)
        let queryTokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
        let decoy = IndexStore.NotDuplicatePair(
            arcidA: queryTokens.enumerated()
                .filter { $0.offset.isMultiple(of: 2) }
                .map(\.element)
                .joined(separator: "-"),
            arcidB: queryTokens.enumerated()
                .filter { !$0.offset.isMultiple(of: 2) }
                .map(\.element)
                .joined(separator: "-"),
            createdAt: target.createdAt + 86_400_000
        )

        XCTAssertEqual(
            results(in: [target, decoy], query: query),
            [target],
            "A pasted display value must not match a row that only contains its tokens across other fields"
        )
    }

    func testSortsCreatedInEitherDirectionWithDeterministicTies() {
        XCTAssertEqual(
            results(sortColumn: .created, ascending: false).map(\.arcidA),
            ["alpha-20", "beta-20", "alpha-10"]
        )
        XCTAssertEqual(
            results(sortColumn: .created, ascending: true).map(\.arcidA),
            ["alpha-10", "alpha-20", "beta-20"]
        )
    }

    func testSortsEachArchiveIDColumnInEitherDirection() {
        XCTAssertEqual(
            results(sortColumn: .leftArchiveID, ascending: true).map(\.arcidA),
            ["alpha-10", "alpha-20", "beta-20"]
        )
        XCTAssertEqual(
            results(sortColumn: .leftArchiveID, ascending: false).map(\.arcidA),
            ["beta-20", "alpha-20", "alpha-10"]
        )
        XCTAssertEqual(
            results(sortColumn: .rightArchiveID, ascending: true).map(\.arcidB),
            ["delta-10", "gamma-20", "zeta-30"]
        )
        XCTAssertEqual(
            results(sortColumn: .rightArchiveID, ascending: false).map(\.arcidB),
            ["zeta-30", "gamma-20", "delta-10"]
        )
    }

    private func results(
        query: String = "",
        sortColumn: NotMatchSortColumn = .created,
        ascending: Bool = false
    ) -> [IndexStore.NotDuplicatePair] {
        results(
            in: pairs,
            query: query,
            sortColumn: sortColumn,
            ascending: ascending
        )
    }

    private func results(
        in pairs: [IndexStore.NotDuplicatePair],
        query: String = "",
        sortColumn: NotMatchSortColumn = .created,
        ascending: Bool = false
    ) -> [IndexStore.NotDuplicatePair] {
        NotMatchListPresentation.filterAndSort(
            pairs,
            query: query,
            sortColumn: sortColumn,
            ascending: ascending
        )
    }
}
