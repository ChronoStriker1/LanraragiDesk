import Foundation

public enum FingerprintKind: Int, Sendable, Codable {
    case dHash = 0
    case aHash = 1

    public var debugName: String {
        switch self {
        case .dHash: return "dHash"
        case .aHash: return "aHash"
        }
    }
}

public enum FingerprintCrop: Int, Sendable, Codable {
    case full = 0
    case center90 = 1
    case center75 = 2

    public var debugName: String {
        switch self {
        case .full: return "full"
        case .center90: return "center90"
        case .center75: return "center75"
        }
    }
}

public struct FingerprintRecord: Sendable, Equatable {
    public var profileID: UUID
    public var arcid: String
    public var kind: FingerprintKind
    public var crop: FingerprintCrop
    public var hash64: UInt64
    public var aspectRatio: Double
    public var thumbChecksum: Data
    public var updatedAt: Int64

    public init(
        profileID: UUID,
        arcid: String,
        kind: FingerprintKind,
        crop: FingerprintCrop,
        hash64: UInt64,
        aspectRatio: Double,
        thumbChecksum: Data,
        updatedAt: Int64
    ) {
        self.profileID = profileID
        self.arcid = arcid
        self.kind = kind
        self.crop = crop
        self.hash64 = hash64
        self.aspectRatio = aspectRatio
        self.thumbChecksum = thumbChecksum
        self.updatedAt = updatedAt
    }
}
