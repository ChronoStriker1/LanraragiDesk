import XCTest
@testable import LanraragiKit

final class RandomArchiveSearchDecodingTests: XCTestCase {
    func testDecodesRandomSearchResultsWithoutRecordsFiltered() throws {
        let json = """
        {
          "data": [
            {
              "arcid": "abc123",
              "title": "Sample Archive",
              "tags": "artist:someone, group:somegroup",
              "pagecount": 12,
              "isnew": true
            },
            {
              "arcid": "def456",
              "title": "Second Archive"
            }
          ],
          "recordsTotal": 2
        }
        """

        let result = try JSONDecoder().decode(RandomArchiveSearch.self, from: Data(json.utf8))
        XCTAssertEqual(result.recordsTotal, 2)
        XCTAssertEqual(result.data.count, 2)
        XCTAssertEqual(result.data[0].arcid, "abc123")
        XCTAssertEqual(result.data[0].title, "Sample Archive")
        XCTAssertEqual(result.data[0].tags, "artist:someone, group:somegroup")
        XCTAssertEqual(result.data[0].pagecount, 12)
        XCTAssertEqual(result.data[0].isnew, true)
        XCTAssertEqual(result.data[1].arcid, "def456")
        XCTAssertEqual(result.data[1].title, "Second Archive")
    }
}
