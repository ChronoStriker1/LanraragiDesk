import AppKit
import Foundation

enum ImageDecodeMetadata: Sendable, Equatable {
    case none
    case pixelSize
    case resolutionText
}

/// The decoded image is created on a worker executor and then handed to the UI actor.
/// NSImage does not declare Sendable, but this value has exclusive ownership while it
/// crosses that boundary and callers only use it after `decode` returns.
struct AsyncDecodedImage: @unchecked Sendable {
    let image: NSImage?
    let pixelSize: CGSize?
    let resolutionText: String?
}

enum AsyncImageDownsampler {
    static func decode(
        _ data: Data,
        maxPixelSize: Int,
        metadata: ImageDecodeMetadata = .none,
        priority: TaskPriority = .userInitiated
    ) async throws -> AsyncDecodedImage {
        try await run(priority: priority) {
            let pixelSize = metadata == .pixelSize
                ? ImageDownsampler.pixelSize(from: data)
                : nil
            let resolutionText = metadata == .resolutionText
                ? ImageDownsampler.resolutionText(from: data)
                : nil
            let image = ImageDownsampler.thumbnail(from: data, maxPixelSize: maxPixelSize)
            return AsyncDecodedImage(
                image: image,
                pixelSize: pixelSize,
                resolutionText: resolutionText
            )
        }
    }

    /// Runs synchronous image work outside the caller's actor and forwards cancellation
    /// to the worker. The checks on both sides prevent a completed stale decode from being
    /// committed after its owning SwiftUI task has been cancelled.
    static func run<Value: Sendable>(
        priority: TaskPriority = .userInitiated,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }

        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }
}
