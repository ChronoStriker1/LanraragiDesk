import XCTest
@testable import LanraragiKit

final class LANraragiClientURLTests: XCTestCase {
    private let apiKey = LANraragiAPIKey("secret-api-key")

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

    func testRelativeURLReceivesAuthorizationAfterResolution() throws {
        let client = makeClient(baseURL: "https://lanraragi.example/library")
        let url = try client.makeAbsoluteURL(from: "/api/archives/abc/page?path=1.jpg")

        let request = makeRequest(url: url, client: client)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), apiKey.bearerHeaderValue)
    }

    func testSameOriginAbsoluteURLReceivesAuthorization() {
        let client = makeClient(baseURL: "https://lanraragi.example/library")
        let request = makeRequest(
            url: URL(string: "https://LANRARAGI.example:443/api/archives/abc/page")!,
            client: client
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), apiKey.bearerHeaderValue)
    }

    func testDifferentHostDoesNotReceiveAuthorization() {
        let client = makeClient(baseURL: "https://lanraragi.example")
        let request = makeRequest(url: URL(string: "https://cdn.example/page.jpg")!, client: client)

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "LanraragiDesk")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en-US")
    }

    func testDifferentSchemeDoesNotReceiveAuthorization() {
        let client = makeClient(baseURL: "https://lanraragi.example")
        let request = makeRequest(url: URL(string: "http://lanraragi.example/page.jpg")!, client: client)

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testDifferentEffectivePortDoesNotReceiveAuthorization() {
        let client = makeClient(baseURL: "https://lanraragi.example")
        let request = makeRequest(
            url: URL(string: "https://lanraragi.example:8443/page.jpg")!,
            client: client
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testMatchingExplicitAndDefaultPortsReceiveAuthorization() {
        let explicitBaseClient = makeClient(baseURL: "http://lanraragi.example:80")
        let implicitRequest = makeRequest(
            url: URL(string: "http://lanraragi.example/page.jpg")!,
            client: explicitBaseClient
        )
        let implicitBaseClient = makeClient(baseURL: "https://lanraragi.example")
        let explicitRequest = makeRequest(
            url: URL(string: "https://lanraragi.example:443/page.jpg")!,
            client: implicitBaseClient
        )

        XCTAssertEqual(implicitRequest.value(forHTTPHeaderField: "Authorization"), apiKey.bearerHeaderValue)
        XCTAssertEqual(explicitRequest.value(forHTTPHeaderField: "Authorization"), apiKey.bearerHeaderValue)
    }

    func testMatchingCustomPortsReceiveAuthorization() {
        let client = makeClient(baseURL: "http://lanraragi.example:3001")
        let request = makeRequest(
            url: URL(string: "http://lanraragi.example:3001/page.jpg")!,
            client: client
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), apiKey.bearerHeaderValue)
    }

    private func makeClient(baseURL: String) -> LANraragiClient {
        LANraragiClient(configuration: .init(baseURL: URL(string: baseURL)!, apiKey: apiKey))
    }

    private func makeRequest(url: URL, client: LANraragiClient) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer should-be-cleared", forHTTPHeaderField: "Authorization")
        client.applyDefaultHeaders(to: &request)
        return request
    }
}
