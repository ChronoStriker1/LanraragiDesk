import CoreGraphics
import Foundation
import XCTest
@testable import LanraragiDesk

@MainActor
final class CoverThumbInvalidationTests: XCTestCase {
    func testRequestKeysIsolateProfilesAndRevisions() {
        let profileA = UUID()
        let profileB = UUID()
        let base = CoverThumbRequestKey(
            profileID: profileA,
            arcid: "shared-arcid",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 0
        )
        let otherProfile = CoverThumbRequestKey(
            profileID: profileB,
            arcid: "shared-arcid",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 0
        )
        let updated = CoverThumbRequestKey(
            profileID: profileA,
            arcid: "shared-arcid",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 1
        )

        XCTAssertNotEqual(base, otherProfile)
        XCTAssertNotEqual(base.cacheKey, otherProfile.cacheKey)
        XCTAssertNotEqual(base, updated)
        XCTAssertNotEqual(base.cacheKey, updated.cacheKey)
    }

    func testInvalidationOnlyAdvancesRequestedProfileAndArchive() {
        let store = CoverThumbInvalidationStore()
        let profileA = UUID()
        let profileB = UUID()

        XCTAssertEqual(store.revision(profileID: profileA, arcid: "a"), 0)
        XCTAssertEqual(store.invalidate(profileID: profileA, arcid: "a"), 1)
        XCTAssertEqual(store.revision(profileID: profileA, arcid: "a"), 1)
        XCTAssertEqual(store.revision(profileID: profileA, arcid: "b"), 0)
        XCTAssertEqual(store.revision(profileID: profileB, arcid: "a"), 0)

        XCTAssertEqual(store.invalidate(profileID: profileA, arcid: "a"), 2)
        XCTAssertEqual(store.revision(profileID: profileA, arcid: "a"), 2)
    }
}
