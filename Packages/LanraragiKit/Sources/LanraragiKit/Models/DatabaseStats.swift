import Foundation

public struct DatabaseStats: Decodable, Sendable, Equatable {
    public var tags: [TagStat]

    public init(tags: [TagStat]) {
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case tags
    }

    public init(from decoder: Decoder) throws {
        // LANraragi has returned both of these shapes in the wild:
        // - [{"tag":"female:ahegao","count":123,"weight":456}, ...] (top-level array)
        // - {"tags":[...]} (wrapped object)
        if let arr = try? decoder.singleValueContainer().decode([TagStat].self) {
            tags = arr
            return
        }

        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = (try? c.decode([TagStat].self, forKey: .tags)) ?? []
    }
}

public struct TagStat: Decodable, Sendable, Equatable, Hashable {
    public var namespace: String?
    public var text: String?
    public var count: Int?
    public var weight: Int?

    public init(namespace: String? = nil, text: String? = nil, count: Int? = nil, weight: Int? = nil) {
        self.namespace = namespace
        self.text = text
        self.count = count
        self.weight = weight
    }

    private enum CodingKeys: String, CodingKey {
        case namespace
        case text
        case tag
        case count
        case weight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Some variants return separate namespace/text, others return a combined "tag" string.
        namespace = try? c.decode(String.self, forKey: .namespace)
        text = try? c.decode(String.self, forKey: .text)

        if (namespace == nil || text == nil), let combined = try? c.decode(String.self, forKey: .tag) {
            if let idx = combined.firstIndex(of: ":") {
                namespace = String(combined[..<idx])
                text = String(combined[combined.index(after: idx)...])
            } else {
                text = combined
            }
        }

        count = LossyInt.decode(from: c, forKey: .count)
        weight = LossyInt.decode(from: c, forKey: .weight)
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
