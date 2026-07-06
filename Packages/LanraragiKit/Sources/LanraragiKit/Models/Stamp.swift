import Foundation

/// A stamp is a small text annotation pinned to a page of an archive.
/// `position` is `"x,y"` in normalized page coordinates (0–100).
public struct Stamp: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var content: String
    public var position: String

    public init(id: String, content: String, position: String) {
        self.id = id
        self.content = content
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case position
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        position = (try? c.decode(String.self, forKey: .position)) ?? ""
    }

    /// Parsed `position`, each axis clamped to 0...100. Nil if the string is malformed.
    public var normalizedPoint: (x: Double, y: Double)? {
        let parts = position.split(separator: ",", maxSplits: 1)
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (min(100, max(0, x)), min(100, max(0, y)))
    }

    public static func positionString(x: Double, y: Double) -> String {
        let cx = min(100, max(0, x))
        let cy = min(100, max(0, y))
        return String(format: "%.2f,%.2f", cx, cy)
    }
}
