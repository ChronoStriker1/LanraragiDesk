import CoreGraphics
import Combine
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

    func testInvalidationOnlyPublishesToMatchingProfileAndArchive() {
        let store = CoverThumbInvalidationStore()
        let profileA = UUID()
        let profileB = UUID()
        let identityA = CoverThumbIdentity(profileID: profileA, arcid: "a")
        let identityB = CoverThumbIdentity(profileID: profileB, arcid: "a")
        let identityOtherArchive = CoverThumbIdentity(profileID: profileA, arcid: "b")
        var receivedA = 0
        var receivedB = 0
        var receivedOtherArchive = 0
        var cancellables: Set<AnyCancellable> = []

        store.publisher(for: identityA)
            .sink { receivedA += 1 }
            .store(in: &cancellables)
        store.publisher(for: identityB)
            .sink { receivedB += 1 }
            .store(in: &cancellables)
        store.publisher(for: identityOtherArchive)
            .sink { receivedOtherArchive += 1 }
            .store(in: &cancellables)

        store.invalidate(profileID: profileA, arcid: "a")

        XCTAssertEqual(receivedA, 1)
        XCTAssertEqual(receivedB, 0)
        XCTAssertEqual(receivedOtherArchive, 0)

        store.invalidate(profileID: profileA, arcid: "a")
        XCTAssertEqual(receivedA, 2)
    }
}
