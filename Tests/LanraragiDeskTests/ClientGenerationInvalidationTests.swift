import Foundation
import LanraragiKit
import XCTest
@testable import LanraragiDesk

@MainActor
final class ClientGenerationInvalidationTests: XCTestCase {
    func testLateCompletionAfterInvalidationWithoutReplacementIsNotCached() async throws {
        let probe = ControlledFetchProbe<ArchiveMetadata>()
        let loader = ArchiveLoader(fetchOverrides: makeArchiveOverrides(
            metadata: { arcid in await probe.fetch(valueID: arcid) }
        ))
        let profile = makeProfile()

        let oldRequest = Task {
            try await loader.metadata(profile: profile, arcid: "shared")
        }
        await probe.waitUntilStarted(callCount: 1)
        await loader.invalidateClient(profileID: profile.id)

        await probe.complete(
            call: 1,
            with: ArchiveMetadata(arcid: "shared", title: "old credentials")
        )
        let oldResult = try await oldRequest.value
        XCTAssertEqual(oldResult.title, "old credentials")

        let freshRequest = Task {
            try await loader.metadata(profile: profile, arcid: "shared")
        }
        await probe.waitUntilStarted(callCount: 2)
        await probe.complete(
            call: 2,
            with: ArchiveMetadata(arcid: "shared", title: "fresh credentials")
        )

        let freshResult = try await freshRequest.value
        XCTAssertEqual(freshResult.title, "fresh credentials")
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testLateMetadataCompletionCannotReplaceNewGenerationCache() async throws {
        let probe = ControlledFetchProbe<ArchiveMetadata>()
        let loader = ArchiveLoader(fetchOverrides: makeArchiveOverrides(
            metadata: { arcid in await probe.fetch(valueID: arcid) }
        ))
        let profile = makeProfile()

        let oldRequest = Task {
            try await loader.metadata(profile: profile, arcid: "shared")
        }
        await probe.waitUntilStarted(callCount: 1)
        await loader.invalidateClient(profileID: profile.id)

        let newRequest = Task {
            try await loader.metadata(profile: profile, arcid: "shared")
        }
        await probe.waitUntilStarted(callCount: 2)

        await probe.complete(
            call: 1,
            with: ArchiveMetadata(arcid: "shared", title: "old credentials")
        )
        let oldResult = try await oldRequest.value
        XCTAssertEqual(oldResult.title, "old credentials")

        await probe.complete(
            call: 2,
            with: ArchiveMetadata(arcid: "shared", title: "new credentials")
        )
        let newResult = try await newRequest.value
        XCTAssertEqual(newResult.title, "new credentials")

        let cached = try await loader.metadata(profile: profile, arcid: "shared")
        XCTAssertEqual(cached.title, "new credentials")
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testLatePageCompletionCannotReplaceNewGenerationCache() async throws {
        let probe = ControlledFetchProbe<ArchiveFilesResponse>()
        let loader = ArchiveLoader(fetchOverrides: makeArchiveOverrides(
            archiveFiles: { arcid, _ in await probe.fetch(valueID: arcid) }
        ))
        let profile = makeProfile()

        let oldRequest = Task {
            try await loader.pageURLs(profile: profile, arcid: "shared")
        }
        await probe.waitUntilStarted(callCount: 1)
        await loader.invalidateClient(profileID: profile.id)

        let newRequest = Task {
            try await loader.pageURLs(profile: profile, arcid: "shared")
        }
        await probe.waitUntilStarted(callCount: 2)

        let oldPages = ArchiveFilesResponse(pages: [
            "https://old.example/1.jpg",
            "https://old.example/2.jpg",
        ])
        await probe.complete(call: 1, with: oldPages)
        let oldResult = try await oldRequest.value
        XCTAssertEqual(oldResult.first?.host, "old.example")

        let newPages = ArchiveFilesResponse(pages: [
            "https://new.example/1.jpg",
            "https://new.example/2.jpg",
        ])
        await probe.complete(call: 2, with: newPages)
        let newResult = try await newRequest.value
        XCTAssertEqual(newResult.first?.host, "new.example")

        let cached = try await loader.pageURLs(profile: profile, arcid: "shared")
        XCTAssertEqual(cached.first?.host, "new.example")
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testLateBytesCompletionCannotReplaceNewGenerationCache() async throws {
        let probe = ControlledFetchProbe<Data>()
        let loader = ArchiveLoader(fetchOverrides: makeArchiveOverrides(
            bytes: { url in await probe.fetch(valueID: url.absoluteString) }
        ))
        let profile = makeProfile()
        let url = URL(string: "https://example.test/page.jpg")!

        let oldRequest = Task {
            try await loader.bytes(profile: profile, url: url)
        }
        await probe.waitUntilStarted(callCount: 1)
        await loader.invalidateClient(profileID: profile.id)

        let newRequest = Task {
            try await loader.bytes(profile: profile, url: url)
        }
        await probe.waitUntilStarted(callCount: 2)

        await probe.complete(call: 1, with: Data([0x01]))
        let oldResult = try await oldRequest.value
        XCTAssertEqual(oldResult, Data([0x01]))

        await probe.complete(call: 2, with: Data([0x02]))
        let newResult = try await newRequest.value
        XCTAssertEqual(newResult, Data([0x02]))

        let cached = try await loader.bytes(profile: profile, url: url)
        XCTAssertEqual(cached, Data([0x02]))
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testLateThumbnailCompletionCannotReplaceNewGenerationCache() async throws {
        let probe = ControlledFetchProbe<Data>()
        let loader = ThumbnailLoader(fetchOverride: .init(bytes: { profile, arcid in
            await probe.fetch(valueID: "\(profile.id)/\(arcid)")
        }))
        let profile = makeProfile()

        let oldRequest = Task {
            try await loader.thumbnailBytes(profile: profile, arcid: "shared")
        }
        await probe.waitUntilStarted(callCount: 1)
        await loader.invalidateClient(profileID: profile.id)

        let newRequest = Task {
            try await loader.thumbnailBytes(profile: profile, arcid: "shared")
        }
        await probe.waitUntilStarted(callCount: 2)

        await probe.complete(call: 1, with: Data([0x01]))
        let oldResult = try await oldRequest.value
        XCTAssertEqual(oldResult, Data([0x01]))

        await probe.complete(call: 2, with: Data([0x02]))
        let newResult = try await newRequest.value
        XCTAssertEqual(newResult, Data([0x02]))

        let cached = try await loader.thumbnailBytes(profile: profile, arcid: "shared")
        XCTAssertEqual(cached, Data([0x02]))
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testProfileInvalidationLeavesOtherProfileCachesIntact() async throws {
        let probe = ImmediateMetadataProbe()
        let loader = ArchiveLoader(fetchOverrides: makeArchiveOverrides(
            metadata: { arcid in await probe.fetch(arcid: arcid) }
        ))
        let firstProfile = makeProfile()
        let secondProfile = makeProfile()

        _ = try await loader.metadata(profile: firstProfile, arcid: "first")
        _ = try await loader.metadata(profile: secondProfile, arcid: "second")
        await loader.invalidateClient(profileID: firstProfile.id)

        _ = try await loader.metadata(profile: secondProfile, arcid: "second")
        _ = try await loader.metadata(profile: firstProfile, arcid: "first")

        let calls = await probe.arcids
        XCTAssertEqual(calls, ["first", "second", "first"])
    }

    private func makeProfile() -> Profile {
        Profile(name: "Test", baseURL: URL(string: "https://example.test")!)
    }

    private func makeArchiveOverrides(
        metadata: @escaping @Sendable (String) async throws -> ArchiveMetadata = {
            ArchiveMetadata(arcid: $0)
        },
        archiveFiles: @escaping @Sendable (String, Bool) async throws -> ArchiveFilesResponse = {
            _, _ in ArchiveFilesResponse(pages: [])
        },
        bytes: @escaping @Sendable (URL) async throws -> Data = { _ in Data() }
    ) -> ArchiveLoaderFetchOverrides {
        ArchiveLoaderFetchOverrides(
            metadata: metadata,
            archiveFiles: archiveFiles,
            absoluteURL: { rawURL in
                guard let url = URL(string: rawURL) else {
                    throw GenerationTestError.invalidURL
                }
                return url
            },
            bytes: bytes
        )
    }
}

private enum GenerationTestError: Error {
    case invalidURL
}

private actor ControlledFetchProbe<Value: Sendable> {
    private struct StartedWaiter {
        let callCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct PendingFetch {
        let valueID: String
        let continuation: CheckedContinuation<Value, Never>
    }

    private var pending: [Int: PendingFetch] = [:]
    private var startedWaiters: [StartedWaiter] = []
    private(set) var callCount = 0

    func fetch(valueID: String) async -> Value {
        callCount += 1
        let call = callCount
        resumeSatisfiedWaiters()
        return await withCheckedContinuation { continuation in
            pending[call] = PendingFetch(valueID: valueID, continuation: continuation)
        }
    }

    func waitUntilStarted(callCount expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(.init(callCount: expected, continuation: continuation))
        }
    }

    func complete(call: Int, with value: Value) {
        pending.removeValue(forKey: call)?.continuation.resume(returning: value)
    }

    private func resumeSatisfiedWaiters() {
        let ready = startedWaiters.filter { $0.callCount <= callCount }
        startedWaiters.removeAll { $0.callCount <= callCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private actor ImmediateMetadataProbe {
    private(set) var arcids: [String] = []

    func fetch(arcid: String) -> ArchiveMetadata {
        arcids.append(arcid)
        return ArchiveMetadata(arcid: arcid)
    }
}
