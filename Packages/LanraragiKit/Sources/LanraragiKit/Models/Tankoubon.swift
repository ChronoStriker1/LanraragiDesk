import Foundation

/// Namespace for LANraragi ID shape helpers.
public enum LANraragiID {
    /// Tankoubon IDs look like `TANK_1749925516`; archive IDs are 40-char SHA1 hex.
    public static func isTankoubon(_ id: String) -> Bool {
        id.hasPrefix("TANK_")
    }
}

public struct Tankoubon: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String?
    public var tags: String?
    public var archives: [String]
    public var progress: Int?
    /// Populated only by the `/full` endpoint.
    public var fullData: [ArchiveMetadata]?

    public init(
        id: String,
        name: String,
        summary: String? = nil,
        tags: String? = nil,
        archives: [String] = [],
        progress: Int? = nil,
        fullData: [ArchiveMetadata]? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.tags = tags
        self.archives = archives
        self.progress = progress
        self.fullData = fullData
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case tags
        case archives
        case progress
        case full_data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        summary = try? c.decode(String.self, forKey: .summary)
        tags = try? c.decode(String.self, forKey: .tags)
        archives = (try? c.decode([String].self, forKey: .archives)) ?? []
        if let i = try? c.decode(Int.self, forKey: .progress) {
            progress = i
        } else if let s = try? c.decode(String.self, forKey: .progress) {
            progress = Int(s)
        } else {
            progress = nil
        }
        fullData = try? c.decode([ArchiveMetadata].self, forKey: .full_data)
    }
}

public struct TankoubonList: Decodable, Sendable, Equatable {
    public var result: [Tankoubon]
    public var total: Int
    public var filtered: Int

    public init(result: [Tankoubon], total: Int, filtered: Int) {
        self.result = result
        self.total = total
        self.filtered = filtered
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case total
        case filtered
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = (try? c.decode([Tankoubon].self, forKey: .result)) ?? []
        total = (try? c.decode(Int.self, forKey: .total)) ?? result.count
        filtered = (try? c.decode(Int.self, forKey: .filtered)) ?? result.count
    }
}

public struct TankoubonFullResponse: Decodable, Sendable, Equatable {
    public var result: Tankoubon
    public var total: Int
    public var filtered: Int

    public init(result: Tankoubon, total: Int, filtered: Int) {
        self.result = result
        self.total = total
        self.filtered = filtered
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case total
        case filtered
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decode(Tankoubon.self, forKey: .result)
        total = (try? c.decode(Int.self, forKey: .total)) ?? result.archives.count
        filtered = (try? c.decode(Int.self, forKey: .filtered)) ?? result.archives.count
    }
}
