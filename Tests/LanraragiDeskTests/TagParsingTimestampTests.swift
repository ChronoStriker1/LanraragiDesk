import Foundation
import XCTest
@testable import LanraragiDesk

final class TagParsingTimestampTests: XCTestCase {
    func testDateAddedParsesUnixSeconds() throws {
        let date = try XCTUnwrap(TagParsing.parseDateAddedTag("artist:test, date_added:1712345678"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_712_345_678, accuracy: 0.001)
    }

    func testDateAddedParsesUnixMilliseconds() throws {
        let date = try XCTUnwrap(TagParsing.parseDateAddedTag("date_added:1712345678123"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_712_345_678.123, accuracy: 0.001)
    }

    func testOneTrillionBoundaryRetainsExistingSecondsBehavior() throws {
        let date = try XCTUnwrap(TagParsing.parseDateAddedTag("date_added:1000000000000"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_000_000_000_000, accuracy: 0.001)
    }

    func testDateAddedTrimsWhitespaceAndQuotes() throws {
        let date = try XCTUnwrap(TagParsing.parseDateAddedTag(" date_added :  '1712345678123' "))
        XCTAssertEqual(date.timeIntervalSince1970, 1_712_345_678.123, accuracy: 0.001)
    }

    func testMalformedDateAddedReturnsNil() {
        XCTAssertNil(TagParsing.parseDateAddedTag("artist:test, date_added:not-a-date"))
    }

    func testNegativeUnixSecondsRemainParseable() throws {
        let date = try XCTUnwrap(TagParsing.parseDateAddedTag("date_added:-1"))
        XCTAssertEqual(date.timeIntervalSince1970, -1, accuracy: 0.001)
    }
}
