import Foundation
import Security
import XCTest
@testable import LanraragiDesk

final class APIKeyCredentialTests: XCTestCase {
    func testLoadUsesProfileSpecificAccount() throws {
        let profileID = UUID(uuidString: "1C111DA7-062E-47CD-8AB3-6AB07F4FC7CE")!
        var requestedAccount: String?

        let key = try APIKeyCredential.load(profileID: profileID) { account in
            requestedAccount = account
            return "secret"
        }

        XCTAssertEqual(requestedAccount, "apiKey.1C111DA7-062E-47CD-8AB3-6AB07F4FC7CE")
        XCTAssertEqual(key.rawValue, "secret")
    }

    func testLoadDistinguishesMissingCredential() {
        XCTAssertThrowsError(
            try APIKeyCredential.load(profileID: UUID()) { _ in nil }
        ) { error in
            XCTAssertEqual(error as? APIKeyCredential.CredentialError, .missing)
            XCTAssertEqual(ErrorPresenter.short(error), "API key missing")
        }
    }

    func testLoadPreservesKeychainFailure() {
        let keychainError = KeychainService.KeychainError(status: errSecInteractionNotAllowed)

        XCTAssertThrowsError(
            try APIKeyCredential.load(profileID: UUID()) { _ in throw keychainError }
        ) { error in
            XCTAssertEqual((error as? KeychainService.KeychainError)?.status, errSecInteractionNotAllowed)
            XCTAssertEqual(
                ErrorPresenter.short(error),
                "Keychain unavailable (\(errSecInteractionNotAllowed))"
            )
        }
    }
}
