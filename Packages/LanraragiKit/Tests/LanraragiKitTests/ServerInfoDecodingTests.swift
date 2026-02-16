import XCTest
@testable import LanraragiKit

final class ServerInfoDecodingTests: XCTestCase {
    func testDecodesTotalsWhenProvided() throws {
        let json = """
        {
          "version": "0.9.0",
          "name": "LANraragi",
          "api_version": 1,
          "server_tracks_progress": true,
          "total_archives": 4321,
          "total_pages_read": 98765
        }
        """

        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.version, "0.9.0")
        XCTAssertEqual(info.name, "LANraragi")
        XCTAssertEqual(info.api_version, 1)
        XCTAssertEqual(info.server_tracks_progress, true)
        XCTAssertEqual(info.total_archives, 4321)
        XCTAssertEqual(info.total_pages_read, 98765)
    }

    func testTotalsRemainOptionalWhenMissing() throws {
        let json = """
        {
          "version": "0.8.9",
          "name": "LANraragi"
        }
        """

        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.version, "0.8.9")
        XCTAssertEqual(info.name, "LANraragi")
        XCTAssertNil(info.total_archives)
        XCTAssertNil(info.total_pages_read)
    }
}
