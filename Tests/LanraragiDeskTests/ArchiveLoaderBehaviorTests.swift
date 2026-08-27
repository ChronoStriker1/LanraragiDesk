import Foundation
import LanraragiKit
import XCTest
@testable import LanraragiDesk

@MainActor
final class ArchiveLoaderBehaviorTests: XCTestCase {
    func testSinglePageListIsVerifiedOnceThenServedFromCache() async throws {
        let pageProbe = PageFetchProbe()
        let loader = ArchiveLoader(fetchOverrides: makeFetchOverrides(
            metadata: { arcid in ArchiveMetadata(arcid: arcid) },
            archiveFiles: { arcid, force in
                await pageProbe.fetch(arcid: arcid, force: force)
            }
        ))
        let profile = makeProfile()

        let first = try await loader.pageURLs(profile: profile, arcid: "one-page")
        let second = try await loader.pageURLs(profile: profile, arcid: "one-page")

        XCTAssertEqual(first, [URL(string: "https://example.test/page-1.jpg")!])
        XCTAssertEqual(second, first)
        let requests = await pageProbe.requests
        XCTAssertEqual(requests, [
            .init(arcid: "one-page", force: false),
            .init(arcid: "one-page", force: true),
        ])
    }

    func testForceRefreshDoesNotCancelExistingMetadataWaiter() async throws {
        let metadataProbe = MetadataFetchProbe()
        let loader = ArchiveLoader(fetchOverrides: makeFetchOverrides(
            metadata: { arcid in
                try await metadataProbe.fetch(arcid: arcid)
            },
            archiveFiles: { _, _ in ArchiveFilesResponse(pages: []) }
        ))
        let profile = makeProfile()

        let existingWaiter = Task {
            try await loader.metadata(profile: profile, arcid: "shared")
        }
        await metadataProbe.waitUntilStarted(callCount: 1)

        let forceRefresh = Task {
            try await loader.metadata(profile: profile, arcid: "shared", forceRefresh: true)
        }
        await metadataProbe.waitUntilStarted(callCount: 2)

        await metadataProbe.complete(call: 1)
        let existingResult = try await existingWaiter.value
        XCTAssertEqual(existingResult.title, "request-1")

        await metadataProbe.complete(call: 2)
        let refreshedResult = try await forceRefresh.value
        XCTAssertEqual(refreshedResult.title, "request-2")
        let callCount = await metadataProbe.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testFailedForceRefreshRetainsLastKnownGoodMetadata() async throws {
        let metadataProbe = KnownGoodMetadataProbe()
        let loader = ArchiveLoader(fetchOverrides: makeFetchOverrides(
            metadata: { arcid in
                try await metadataProbe.fetch(arcid: arcid)
            },
            archiveFiles: { _, _ in ArchiveFilesResponse(pages: []) }
        ))
        let profile = makeProfile()

        let cached = try await loader.metadata(profile: profile, arcid: "known-good")
        XCTAssertEqual(cached.title, "cached")

        do {
            _ = try await loader.metadata(profile: profile, arcid: "known-good", forceRefresh: true)
            XCTFail("Expected forced refresh to fail")
        } catch TestError.refreshFailed {
            // Expected: a transient refresh failure must not discard cached metadata.
        }

        let afterFailure = try await loader.metadata(profile: profile, arcid: "known-good")
        XCTAssertEqual(afterFailure, cached)
        let callCount = await metadataProbe.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testPageBytesCoalesceInFlightThenUseCache() async throws {
        let byteProbe = ByteFetchProbe()
        let loader = ArchiveLoader(fetchOverrides: makeFetchOverrides(
            metadata: { arcid in ArchiveMetadata(arcid: arcid) },
            archiveFiles: { _, _ in ArchiveFilesResponse(pages: []) },
            bytes: { url in
                await byteProbe.fetch(url: url)
            }
        ))
        let profile = makeProfile()
        let pageURL = URL(string: "https://example.test/page.jpg")!

        async let first = loader.bytes(profile: profile, url: pageURL)
        await byteProbe.waitUntilStarted()
        async let coalesced = loader.bytes(profile: profile, url: pageURL)
        await byteProbe.complete()

        let expected = Data([0x01, 0x02, 0x03])
        let firstResult = try await first
        let coalescedResult = try await coalesced
        XCTAssertEqual(firstResult, expected)
        XCTAssertEqual(coalescedResult, expected)

        let cachedResult = try await loader.bytes(profile: profile, url: pageURL)
        XCTAssertEqual(cachedResult, expected)
        let callCount = await byteProbe.callCount
        XCTAssertEqual(callCount, 1)
    }

    private func makeProfile() -> Profile {
        Profile(name: "Test", baseURL: URL(string: "https://example.test")!)
    }

    private func makeFetchOverrides(
        metadata: @escaping @Sendable (String) async throws -> ArchiveMetadata,
        archiveFiles: @escaping @Sendable (String, Bool) async throws -> ArchiveFilesResponse,
        bytes: @escaping @Sendable (URL) async throws -> Data = { _ in Data() }
    ) -> ArchiveLoaderFetchOverrides {
        ArchiveLoaderFetchOverrides(
            metadata: metadata,
            archiveFiles: archiveFiles,
            absoluteURL: { rawURL in
                guard let url = URL(string: rawURL) else {
                    throw TestError.invalidURL(rawURL)
                }
                return url
            },
            bytes: bytes
        )
    }
}

private enum TestError: Error {
    case invalidURL(String)
    case refreshFailed
}

private actor PageFetchProbe {
    struct Request: Equatable, Sendable {
        let arcid: String
        let force: Bool
    }

    private(set) var requests: [Request] = []

    func fetch(arcid: String, force: Bool) -> ArchiveFilesResponse {
        requests.append(.init(arcid: arcid, force: force))
        return ArchiveFilesResponse(pages: ["https://example.test/page-1.jpg"])
    }
}

private actor KnownGoodMetadataProbe {
    private(set) var callCount = 0

    func fetch(arcid: String) throws -> ArchiveMetadata {
        callCount += 1
        if callCount == 1 {
            return ArchiveMetadata(arcid: arcid, title: "cached")
        }
        throw TestError.refreshFailed
    }
}

private actor ByteFetchProbe {
    private var completions: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0

    func fetch(url _: URL) async -> Data {
        callCount += 1
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        await withCheckedContinuation { continuation in
            completions.append(continuation)
        }
        return Data([0x01, 0x02, 0x03])
    }

    func waitUntilStarted() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func complete() {
        let pending = completions
        completions.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor MetadataFetchProbe {
    private struct StartWaiter {
        let callCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var completions: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [StartWaiter] = []
    private(set) var callCount = 0

    func fetch(arcid: String) async throws -> ArchiveMetadata {
        callCount += 1
        let call = callCount
        resumeSatisfiedStartWaiters()

        await withCheckedContinuation { continuation in
            completions[call] = continuation
        }
        try Task.checkCancellation()
        return ArchiveMetadata(arcid: arcid, title: "request-\(call)")
    }

    func waitUntilStarted(callCount expectedCount: Int) async {
        guard callCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(.init(callCount: expectedCount, continuation: continuation))
        }
    }

    func complete(call: Int) {
        completions.removeValue(forKey: call)?.resume()
    }

    private func resumeSatisfiedStartWaiters() {
        let ready = startWaiters.filter { $0.callCount <= callCount }
        startWaiters.removeAll { $0.callCount <= callCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
