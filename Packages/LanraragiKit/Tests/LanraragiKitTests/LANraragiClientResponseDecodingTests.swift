import XCTest
@testable import LanraragiKit

final class LANraragiClientResponseDecodingTests: XCTestCase {
    func testArchiveTankoubonsRejectsMalformedJSON() {
        XCTAssertThrowsError(
            try LANraragiClient.decodeArchiveTankoubonsResponse(from: Data("not-json".utf8))
        ) { error in
            guard let clientError = error as? LANraragiError, case .decoding = clientError else {
                return XCTFail("Expected decoding error, got \(error)")
            }
        }
    }

    func testArchiveTankoubonsRejectsMissingArray() {
        XCTAssertThrowsError(
            try LANraragiClient.decodeArchiveTankoubonsResponse(from: Data(#"{"tankoubons":"bad"}"#.utf8))
        ) { error in
            guard let clientError = error as? LANraragiError, case .decoding = clientError else {
                return XCTFail("Expected decoding error, got \(error)")
            }
        }
    }

    func testStampedPagesAcceptsNumericStringsAndSorts() throws {
        let data = Data(#"{"result":["12",2,7]}"#.utf8)
        XCTAssertEqual(try LANraragiClient.decodeStampedPagesResponse(from: data), [2, 7, 12])
    }

    func testStampedPagesRejectsInvalidValues() {
        let data = Data(#"{"result":[1,"page-two"]}"#.utf8)
        XCTAssertThrowsError(try LANraragiClient.decodeStampedPagesResponse(from: data)) { error in
            guard let clientError = error as? LANraragiError, case .decoding = clientError else {
                return XCTFail("Expected decoding error, got \(error)")
            }
        }
    }

    func testAddedStampRequiresNonEmptyID() throws {
        XCTAssertEqual(
            try LANraragiClient.decodeAddedStampResponse(from: Data(#"{"stamp_id":"stamp-1"}"#.utf8)),
            "stamp-1"
        )

        XCTAssertThrowsError(
            try LANraragiClient.decodeAddedStampResponse(from: Data(#"{"stamp_id":""}"#.utf8))
        ) { error in
            guard let clientError = error as? LANraragiError, case .decoding = clientError else {
                return XCTFail("Expected decoding error, got \(error)")
            }
        }
    }

    func testCategoriesRejectsUnexpectedTopLevelShape() {
        XCTAssertThrowsError(
            try LANraragiClient.decodeCategoriesResponse(from: Data(#""categories""#.utf8))
        ) { error in
            guard let clientError = error as? LANraragiError, case .decoding = clientError else {
                return XCTFail("Expected decoding error, got \(error)")
            }
        }
    }
}
