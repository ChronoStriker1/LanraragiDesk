import AppKit
import CoreGraphics
import Combine
import Foundation
import XCTest
@testable import LanraragiDesk

@MainActor
final class CoverThumbInvalidationTests: XCTestCase {
    func testLoadOwnershipOnlyPermitsCurrentUncancelledGeneration() {
        let request = CoverThumbRequestKey(
            profileID: UUID(),
            arcid: "archive-a",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 0
        )
        let current = CoverThumbLoadToken(request: request)

        XCTAssertTrue(
            CoverThumbLoadOwnership.permitsWrite(
                active: current,
                candidate: current,
                isCancelled: false
            )
        )
        XCTAssertFalse(
            CoverThumbLoadOwnership.permitsWrite(
                active: current,
                candidate: current,
                isCancelled: true
            )
        )
        XCTAssertFalse(
            CoverThumbLoadOwnership.permitsWrite(
                active: nil,
                candidate: current,
                isCancelled: false
            )
        )
    }

    func testLoadOwnershipRejectsStaleCompletionWithSameRequestKey() {
        let request = CoverThumbRequestKey(
            profileID: UUID(),
            arcid: "archive-a",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 0
        )
        let stale = CoverThumbLoadToken(
            request: request,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let replacement = CoverThumbLoadToken(
            request: request,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        XCTAssertNotEqual(stale, replacement)
        XCTAssertFalse(
            CoverThumbLoadOwnership.permitsWrite(
                active: replacement,
                candidate: stale,
                isCancelled: false
            )
        )
    }

    func testLoadOwnershipRejectsCompletionForDifferentArchive() {
        let profileID = UUID()
        let firstRequest = CoverThumbRequestKey(
            profileID: profileID,
            arcid: "archive-a",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 0
        )
        let replacementRequest = CoverThumbRequestKey(
            profileID: profileID,
            arcid: "archive-b",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 0
        )
        let stale = CoverThumbLoadToken(request: firstRequest)
        let replacement = CoverThumbLoadToken(request: replacementRequest)

        XCTAssertFalse(
            CoverThumbLoadOwnership.permitsWrite(
                active: replacement,
                candidate: stale,
                isCancelled: false
            )
        )
    }

    func testCommitGateOnlyInvokesMutationForCurrentUncancelledLoad() {
        let request = CoverThumbRequestKey(
            profileID: UUID(),
            arcid: "archive-a",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 0
        )
        let stale = CoverThumbLoadToken(
            request: request,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let replacement = CoverThumbLoadToken(
            request: request,
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        var mutationCount = 0
        let recordImageAndCacheMutation = { mutationCount += 1 }

        XCTAssertFalse(
            CoverThumbLoadOwnership.commitIfCurrent(
                active: replacement,
                candidate: stale,
                isCancelled: false,
                mutation: recordImageAndCacheMutation
            )
        )
        XCTAssertFalse(
            CoverThumbLoadOwnership.commitIfCurrent(
                active: replacement,
                candidate: replacement,
                isCancelled: true,
                mutation: recordImageAndCacheMutation
            )
        )
        XCTAssertFalse(
            CoverThumbLoadOwnership.commitIfCurrent(
                active: nil,
                candidate: replacement,
                isCancelled: false,
                mutation: recordImageAndCacheMutation
            )
        )
        XCTAssertEqual(mutationCount, 0)

        XCTAssertTrue(
            CoverThumbLoadOwnership.commitIfCurrent(
                active: replacement,
                candidate: replacement,
                isCancelled: false,
                mutation: recordImageAndCacheMutation
            )
        )
        XCTAssertEqual(mutationCount, 1)
    }

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

    func testInvalidationEvictsEveryTargetVariantAndRetainsOtherIdentity() {
        let store = CoverThumbInvalidationStore()
        let profileA = UUID()
        let profileB = UUID()
        let targetBase = CoverThumbRequestKey(
            profileID: profileA,
            arcid: "shared-arcid",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 0
        )
        let targetRevision = CoverThumbRequestKey(
            profileID: profileA,
            arcid: "shared-arcid",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 1
        )
        let targetSizeVariant = CoverThumbRequestKey(
            profileID: profileA,
            arcid: "shared-arcid",
            size: CGSize(width: 112, height: 144),
            contentInset: 0,
            reloadToken: 3,
            revision: 0
        )
        let otherIdentity = CoverThumbRequestKey(
            profileID: profileB,
            arcid: "shared-arcid",
            size: CGSize(width: 56, height: 72),
            contentInset: 4,
            reloadToken: 0,
            revision: 0
        )
        let image = NSImage(size: CGSize(width: 8, height: 8))

        for request in [targetBase, targetRevision, targetSizeVariant, otherIdentity] {
            CoverThumbCacheTestSupport.insert(image, for: request)
            XCTAssertTrue(CoverThumbCacheTestSupport.contains(request))
        }

        store.invalidate(profileID: profileA, arcid: "shared-arcid")

        XCTAssertFalse(CoverThumbCacheTestSupport.contains(targetBase))
        XCTAssertFalse(CoverThumbCacheTestSupport.contains(targetRevision))
        XCTAssertFalse(CoverThumbCacheTestSupport.contains(targetSizeVariant))
        XCTAssertTrue(CoverThumbCacheTestSupport.contains(otherIdentity))

        store.invalidate(profileID: profileB, arcid: "shared-arcid")
        XCTAssertFalse(CoverThumbCacheTestSupport.contains(otherIdentity))
    }
}
