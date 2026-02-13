import XCTest
@testable import LanraragiKit

final class LANraragiAPIKeyTests: XCTestCase {
    func testBearerHeaderValueBase64EncodesUTF8() {
        let key = LANraragiAPIKey("abc123")
        XCTAssertEqual(key.bearerHeaderValue, "Bearer YWJjMTIz")
    }
}
