import Foundation
import XCTest
@testable import LanraragiDesk

@MainActor
final class ProfileStoreTests: XCTestCase {
    func testMismatchedIDIsRejectedWithoutChangingProfileOrCredentials() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let existing = Profile(
            id: UUID(uuidString: "EAEF3E9D-596B-46CB-A2CB-B10E77E9B534")!,
            name: "Existing",
            baseURL: URL(string: "http://existing.example")!
        )
        try fixture.writeProfiles([existing])
        let credentials = FakeProfileCredentialStore()
        let store = ProfileStore(fileURL: fixture.fileURL, credentialStore: credentials)
        let replacement = Profile(
            id: UUID(uuidString: "F3062F1B-4C23-4247-BF6F-67264770633B")!,
            name: "Replacement",
            baseURL: URL(string: "http://replacement.example")!
        )

        XCTAssertFalse(store.canUpsert(profileID: replacement.id))
        let result = try store.upsert(replacement)

        XCTAssertEqual(result, .rejectedMismatchedID(existingID: existing.id))
        XCTAssertEqual(store.profiles, [existing])
        XCTAssertEqual(try fixture.readProfiles(), [existing])
        XCTAssertEqual(credentials.deletedProfileIDs, [])
    }

    func testMatchingIDUpdatesProfileWithoutDeletingCredential() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let profileID = UUID(uuidString: "EAEF3E9D-596B-46CB-A2CB-B10E77E9B534")!
        let existing = Profile(
            id: profileID,
            name: "Existing",
            baseURL: URL(string: "http://existing.example")!
        )
        try fixture.writeProfiles([existing])
        let credentials = FakeProfileCredentialStore()
        let store = ProfileStore(fileURL: fixture.fileURL, credentialStore: credentials)
        let updated = Profile(
            id: profileID,
            name: "Updated",
            baseURL: URL(string: "https://updated.example")!
        )

        XCTAssertTrue(store.canUpsert(profileID: updated.id))
        let result = try store.upsert(updated)

        XCTAssertEqual(result, .updated)
        XCTAssertEqual(store.profiles, [updated])
        XCTAssertEqual(try fixture.readProfiles(), [updated])
        XCTAssertEqual(credentials.deletedProfileIDs, [])
    }

    func testEmptyStoreInsertPersistsWithoutDeletingCredential() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credentials = FakeProfileCredentialStore()
        let store = ProfileStore(fileURL: fixture.fileURL, credentialStore: credentials)
        let profile = Profile(
            id: UUID(uuidString: "AEE7FA85-D1F9-4DB7-9449-31015F2A95F1")!,
            name: "Inserted",
            baseURL: URL(string: "http://inserted.example")!
        )

        XCTAssertTrue(store.canUpsert(profileID: profile.id))
        XCTAssertEqual(try store.upsert(profile), .inserted)
        XCTAssertEqual(store.profiles, [profile])
        XCTAssertEqual(try fixture.readProfiles(), [profile])
        XCTAssertEqual(credentials.deletedProfileIDs, [])
    }

    func testInsertWriteFailureRollsBackInMemoryProfile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let credentials = FakeProfileCredentialStore()
        let store = ProfileStore(fileURL: fixture.directoryURL, credentialStore: credentials)
        let profile = Profile(
            name: "Cannot persist",
            baseURL: URL(string: "http://failure.example")!
        )

        XCTAssertThrowsError(try store.upsert(profile))
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(credentials.deletedProfileIDs, [])
    }

    func testLoadTruncationDeletesDiscardedCredentialsAfterPersisting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let kept = Profile(name: "Kept", baseURL: URL(string: "http://kept.example")!)
        let discarded = Profile(name: "Discarded", baseURL: URL(string: "http://discarded.example")!)
        try fixture.writeProfiles([kept, discarded])
        let credentials = FakeProfileCredentialStore()

        let store = ProfileStore(fileURL: fixture.fileURL, credentialStore: credentials)

        XCTAssertEqual(store.profiles, [kept])
        XCTAssertEqual(try fixture.readProfiles(), [kept])
        XCTAssertEqual(credentials.deletedProfileIDs, [discarded.id])
    }
}

private final class FakeProfileCredentialStore: ProfileCredentialStoring {
    private(set) var deletedProfileIDs: [UUID] = []

    func deleteAPIKey(for profileID: UUID) throws {
        deletedProfileIDs.append(profileID)
    }
}

private struct Fixture {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func writeProfiles(_ profiles: [Profile]) throws {
        try JSONEncoder().encode(profiles).write(to: fileURL, options: [.atomic])
    }

    func readProfiles() throws -> [Profile] {
        try JSONDecoder().decode([Profile].self, from: Data(contentsOf: fileURL))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
