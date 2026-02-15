import Foundation

public struct Category: Decodable, Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var pinned: Bool

    public init(id: String, name: String, pinned: Bool = false) {
        self.id = id
        self.name = name
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case pinned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        pinned = LossyBool.decode(from: c, forKey: .pinned) ?? false
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

