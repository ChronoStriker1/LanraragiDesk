import Foundation

public struct PluginInfo: Sendable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var description: String?

    public init(id: String, title: String, description: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
    }
}

