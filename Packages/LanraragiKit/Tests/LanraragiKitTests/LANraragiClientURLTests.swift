import XCTest
@testable import LanraragiKit

final class LANraragiClientURLTests: XCTestCase {
    func testMakeAbsoluteURLResolvesRelativePathWithHTTPSBase() throws {
        let client = LANraragiClient(configuration: .init(baseURL: URL(string: "https://lanraragi.cstriker.us")!))
        let url = try client.makeAbsoluteURL(from: "/api/archives/abc/metadata")
        XCTAssertEqual(url.absoluteString, "https://lanraragi.cstriker.us/api/archives/abc/metadata")
    }

    func testMakeAbsoluteURLResolvesRelativePathWithHTTPBase() throws {
        let client = LANraragiClient(configuration: .init(baseURL: URL(string: "http://192.168.2.4:3001")!))
        let url = try client.makeAbsoluteURL(from: "/api/archives/abc/metadata")
        XCTAssertEqual(url.absoluteString, "http://192.168.2.4:3001/api/archives/abc/metadata")
    }

    func testMakeAbsoluteURLPreservesAbsoluteURLs() throws {
        let client = LANraragiClient(configuration: .init(baseURL: URL(string: "https://lanraragi.cstriker.us")!))
        let absolute = "https://example.net/path/file.jpg"
        let url = try client.makeAbsoluteURL(from: absolute)
        XCTAssertEqual(url.absoluteString, absolute)
    }
}
