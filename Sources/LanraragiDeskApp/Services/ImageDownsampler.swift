import AppKit
import CoreGraphics
import ImageIO
import Foundation

enum ImageDownsampler {
    static func resolutionText(from data: Data) -> String? {
        let cfData = data as CFData
        guard let src = CGImageSourceCreateWithData(cfData, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let w = props[kCGImagePropertyPixelWidth] as? Int
        let h = props[kCGImagePropertyPixelHeight] as? Int
        guard let w, let h, w > 0, h > 0 else { return nil }
        return "\(w)x\(h)"
    }

    static func thumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0 else { return NSImage(data: data) }

        let cfData = data as CFData
        guard let src = CGImageSourceCreateWithData(cfData, nil) else { return NSImage(data: data) }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return NSImage(data: data) }
        return NSImage(cgImage: cg, size: .zero)
    }
}

