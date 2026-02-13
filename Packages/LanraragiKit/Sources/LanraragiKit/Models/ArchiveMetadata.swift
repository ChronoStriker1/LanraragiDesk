import Foundation

public struct ArchiveMetadata: Decodable, Sendable, Equatable {
    public var arcid: String
    public var title: String?
    public var tags: String?
    public var summary: String?
    public var pagecount: Int?
    public var filename: String?
    public var fileExtension: String?
    public var category: String?
    public var isnew: Bool?
    public var progress: Int?
    public var lastreadtime: Int?

    public init(
        arcid: String,
        title: String? = nil,
        tags: String? = nil,
        summary: String? = nil,
        pagecount: Int? = nil,
        filename: String? = nil,
        fileExtension: String? = nil,
        category: String? = nil,
        isnew: Bool? = nil,
        progress: Int? = nil,
        lastreadtime: Int? = nil
    ) {
        self.arcid = arcid
        self.title = title
        self.tags = tags
        self.summary = summary
        self.pagecount = pagecount
        self.filename = filename
        self.fileExtension = fileExtension
        self.category = category
        self.isnew = isnew
        self.progress = progress
        self.lastreadtime = lastreadtime
    }

    private enum CodingKeys: String, CodingKey {
        case arcid
        case title
        case tags
        case summary
        case pagecount
        case filename
        case `extension`
        case category
        case isnew
        case progress
        case lastreadtime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        arcid = (try? c.decode(String.self, forKey: .arcid)) ?? ""
        title = try? c.decode(String.self, forKey: .title)
        tags = try? c.decode(String.self, forKey: .tags)
        summary = try? c.decode(String.self, forKey: .summary)
        filename = try? c.decode(String.self, forKey: .filename)
        fileExtension = try? c.decode(String.self, forKey: .extension)
        category = try? c.decode(String.self, forKey: .category)

        pagecount = LossyInt.decode(from: c, forKey: .pagecount)
        progress = LossyInt.decode(from: c, forKey: .progress)
        lastreadtime = LossyInt.decode(from: c, forKey: .lastreadtime)
        isnew = LossyBool.decode(from: c, forKey: .isnew)
    }
}

private enum LossyBool {
    static func decode<K: CodingKey>(from c: KeyedDecodingContainer<K>, forKey key: K) -> Bool? {
        if let b = try? c.decode(Bool.self, forKey: key) { return b }
        if let s = try? c.decode(String.self, forKey: key) {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        if let i = try? c.decode(Int.self, forKey: key) {
            return i != 0
        }
        return nil
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
