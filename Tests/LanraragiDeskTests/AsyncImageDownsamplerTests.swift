import Foundation
import XCTest
@testable import LanraragiDesk

@MainActor
final class AsyncImageDownsamplerTests: XCTestCase {
    func testLoadOwnershipOnlyLetsCurrentUncancelledLoadMutate() {
        var ownership = ImageLoadOwnership()
        let replaced = ownership.begin(id: UUID(uuidString: "09BC2C78-0D64-4F1A-98DB-2EFCD8467A39")!)
        let current = ownership.begin(id: UUID(uuidString: "A779CF59-EC46-45A8-96AE-19DB241AA2BA")!)
        var mutations: [String] = []

        XCTAssertFalse(ownership.performIfCurrent(replaced, isCancelled: false) {
            mutations.append("stale")
        })
        XCTAssertFalse(ownership.performIfCurrent(current, isCancelled: true) {
            mutations.append("cancelled")
        })
        XCTAssertTrue(ownership.performIfCurrent(current, isCancelled: false) {
            mutations.append("current")
        })
        XCTAssertEqual(mutations, ["current"])
    }

    func testInvalidatingOwnershipPreventsMutation() {
        var ownership = ImageLoadOwnership()
        let load = ownership.begin()
        ownership.invalidate()
        var mutated = false

        XCTAssertFalse(ownership.performIfCurrent(load, isCancelled: false) {
            mutated = true
        })
        XCTAssertFalse(mutated)
    }

    func testDecodeReturnsImageAndRequestedMetadata() async throws {
        // A 1x1 PNG keeps the test independent of AppKit drawing and display state.
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))

        let decoded = try await AsyncImageDownsampler.decode(
            png,
            maxPixelSize: 16,
            metadata: .pixelSize
        )

        XCTAssertNotNil(decoded.image)
        XCTAssertEqual(decoded.pixelSize?.width, 1)
        XCTAssertEqual(decoded.pixelSize?.height, 1)
        XCTAssertNil(decoded.resolutionText)
    }

    func testRunDoesNotExecuteSynchronousWorkOnMainThread() async throws {
        let ranOnMainThread = try await AsyncImageDownsampler.run {
            Thread.isMainThread
        }

        XCTAssertFalse(ranOnMainThread)
    }

    func testRunForwardsCallerCancellationToWorker() async throws {
        let workerStarted = DispatchSemaphore(value: 0)
        let releaseWorker = DispatchSemaphore(value: 0)
        let workerObservation = LockedBoolean()
        let task = Task {
            try await AsyncImageDownsampler.run {
                workerStarted.signal()
                releaseWorker.wait()
                workerObservation.set(Task.isCancelled)
                return 1
            }
        }

        await Task.detached {
            workerStarted.wait()
        }.value
        task.cancel()
        releaseWorker.signal()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertTrue(workerObservation.value)
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set(_ value: Bool) {
        lock.withLock { storage = value }
    }
}
