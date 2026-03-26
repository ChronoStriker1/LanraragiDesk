import Foundation

public struct ArchiveIdOnly: Decodable, Sendable, Equatable {
    public var arcid: String

    public init(arcid: String) {
        self.arcid = arcid
    }
}

public struct ArchiveSearch: Decodable, Sendable, Equatable {
    public var data: [ArchiveIdOnly]
    public var recordsFiltered: Int
    public var recordsTotal: Int

    public init(data: [ArchiveIdOnly], recordsFiltered: Int, recordsTotal: Int) {
        self.data = data
        self.recordsFiltered = recordsFiltered
        self.recordsTotal = recordsTotal
    }
}

public struct RandomArchiveSearch: Decodable, Sendable, Equatable {
    public var data: [ArchiveMetadata]
    public var recordsTotal: Int

    public init(data: [ArchiveMetadata], recordsTotal: Int) {
        self.data = data
        self.recordsTotal = recordsTotal
    }

    private enum CodingKeys: String, CodingKey {
        case data
        case recordsTotal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = (try? c.decode([ArchiveMetadata].self, forKey: .data)) ?? []
        recordsTotal = LossyInt.decode(from: c, forKey: .recordsTotal) ?? data.count
    }
}

private enum LossyInt {
    static func decode<K: CodingKey>(from c: KeyedDecodingContainer<K>, forKey key: K) -> Int? {
        if let i = try? c.decode(Int.self, forKey: key) { return i }
        if let s = try? c.decode(String.self, forKey: key), let i = Int(s) { return i }
        if let d = try? c.decode(Double.self, forKey: key) { return Int(d) }
        return nil
    }
}
