import Accelerate
import CryptoKit
import Foundation
import ImageIO

public enum Fingerprinter {
    public enum FingerprintError: Error, Sendable {
        case decodeFailed
        case vImageError(Int)
    }

    public struct Result: Sendable {
        public var aspectRatio: Double
        public var checksumSHA256: Data
        public var records: [(FingerprintKind, FingerprintCrop, UInt64)]

        public init(aspectRatio: Double, checksumSHA256: Data, records: [(FingerprintKind, FingerprintCrop, UInt64)]) {
            self.aspectRatio = aspectRatio
            self.checksumSHA256 = checksumSHA256
            self.records = records
        }
    }

    public static func compute(from thumbnailBytes: Data) throws -> Result {
        let checksum = Data(SHA256.hash(data: thumbnailBytes))

        guard let cg = decodeCGImage(thumbnailBytes) else {
            throw FingerprintError.decodeFailed
        }

        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else {
            throw FingerprintError.decodeFailed
        }

        let aspectRatio = Double(width) / Double(height)

        let argb = try makeARGB8888Buffer(from: cg)
        defer { free(argb.data) }

        // Crops are computed in-place by referencing the underlying ARGB buffer.
        let crops: [(FingerprintCrop, vImage_Buffer)] = [
            (.full, argb),
            (.center90, centerCrop(argb, scale: 0.90)),
            (.center75, centerCrop(argb, scale: 0.75)),
        ]

        var out: [(FingerprintKind, FingerprintCrop, UInt64)] = []
        out.reserveCapacity(crops.count * 2)

        for (cropKind, cropBuf) in crops {
            let dh = try dHash(from: cropBuf)
            out.append((.dHash, cropKind, dh))

            let ah = try aHash(from: cropBuf)
            out.append((.aHash, cropKind, ah))
        }

        return Result(aspectRatio: aspectRatio, checksumSHA256: checksum, records: out)
    }

    private static func decodeCGImage(_ data: Data) -> CGImage? {
        let opts: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, opts) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, opts)
    }

    private static func makeARGB8888Buffer(from cg: CGImage) throws -> vImage_Buffer {
        let width = cg.width
        let height = cg.height
        let bytesPerRow = width * 4

        guard let data = malloc(height * bytesPerRow) else {
            throw FingerprintError.decodeFailed
        }

        guard let ctx = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            free(data)
            throw FingerprintError.decodeFailed
        }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        return vImage_Buffer(
            data: data,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
    }

    private static func centerCrop(_ src: vImage_Buffer, scale: Double) -> vImage_Buffer {
        let w = Int(src.width)
        let h = Int(src.height)

        let cw = max(1, Int(Double(w) * scale))
        let ch = max(1, Int(Double(h) * scale))

        let x = max(0, (w - cw) / 2)
        let y = max(0, (h - ch) / 2)

        let byteOffset = y * src.rowBytes + x * 4
        let ptr = src.data.advanced(by: byteOffset)
        return vImage_Buffer(
            data: ptr,
            height: vImagePixelCount(ch),
            width: vImagePixelCount(cw),
            rowBytes: src.rowBytes
        )
    }

    private static func dHash(from cropARGB: vImage_Buffer) throws -> UInt64 {
        // 9x8 luma
        let luma = try scaledLuma(from: cropARGB, dstWidth: 9, dstHeight: 8)
        return dHashFromLuma(width: 9, height: 8, pixels: luma)
    }

    private static func aHash(from cropARGB: vImage_Buffer) throws -> UInt64 {
        // 8x8 luma
        let luma = try scaledLuma(from: cropARGB, dstWidth: 8, dstHeight: 8)
        return aHashFromLuma(width: 8, height: 8, pixels: luma)
    }

    private static func scaledLuma(from src: vImage_Buffer, dstWidth: Int, dstHeight: Int) throws -> [UInt8] {
        var srcCopy = src

        // Scale ARGB8888 -> ARGB8888
        let scaledRowBytes = dstWidth * 4
        guard let scaledData = malloc(dstHeight * scaledRowBytes) else {
            throw FingerprintError.decodeFailed
        }
        defer { free(scaledData) }

        var scaled = vImage_Buffer(
            data: scaledData,
            height: vImagePixelCount(dstHeight),
            width: vImagePixelCount(dstWidth),
            rowBytes: scaledRowBytes
        )

        let scaleErr = vImageScale_ARGB8888(&srcCopy, &scaled, nil, vImage_Flags(kvImageHighQualityResampling))
        guard scaleErr == kvImageNoError else {
            throw FingerprintError.vImageError(Int(scaleErr))
        }

        // Convert ARGB8888 -> Planar8 luma using matrix multiply.
        guard let lumaData = malloc(dstHeight * dstWidth) else {
            throw FingerprintError.decodeFailed
        }
        defer { free(lumaData) }

        var luma = vImage_Buffer(
            data: lumaData,
            height: vImagePixelCount(dstHeight),
            width: vImagePixelCount(dstWidth),
            rowBytes: dstWidth
        )

        // Matrix expects ARGB ordering. We ignore alpha.
        var matrix: [Int16] = [0, 77, 150, 29] // A, R, G, B (sum=256)
        let divisor: Int32 = 256
        let mulErr = vImageMatrixMultiply_ARGB8888ToPlanar8(
            &scaled,
            &luma,
            &matrix,
            divisor,
            nil,
            0,
            vImage_Flags(kvImageNoFlags)
        )
        guard mulErr == kvImageNoError else {
            throw FingerprintError.vImageError(Int(mulErr))
        }

        let count = dstWidth * dstHeight
        let buf = UnsafeBufferPointer(start: luma.data.assumingMemoryBound(to: UInt8.self), count: count)
        return Array(buf)
    }

    private static func dHashFromLuma(width: Int, height: Int, pixels: [UInt8]) -> UInt64 {
        precondition(width == 9)
        precondition(height == 8)
        precondition(pixels.count == width * height)

        var out: UInt64 = 0
        var bit: UInt64 = 1 << 63

        for y in 0..<height {
            let row = y * width
            for x in 0..<8 {
                let a = pixels[row + x]
                let b = pixels[row + x + 1]
                if a > b {
                    out |= bit
                }
                bit >>= 1
            }
        }

        return out
    }

    private static func aHashFromLuma(width: Int, height: Int, pixels: [UInt8]) -> UInt64 {
        precondition(width == 8)
        precondition(height == 8)
        precondition(pixels.count == width * height)

        var sum: Int = 0
        for p in pixels {
            sum += Int(p)
        }
        let mean = sum / pixels.count

        var out: UInt64 = 0
        var bit: UInt64 = 1 << 63
        for p in pixels {
            if Int(p) > mean {
                out |= bit
            }
            bit >>= 1
        }
        return out
    }
}
