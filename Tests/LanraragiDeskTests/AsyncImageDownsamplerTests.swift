import Foundation
import XCTest
@testable import LanraragiDesk

@MainActor
final class AsyncImageDownsamplerTests: XCTestCase {
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
        let task = Task {
            try await AsyncImageDownsampler.run {
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                return true
            }
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }
}
