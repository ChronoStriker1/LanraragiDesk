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
}
