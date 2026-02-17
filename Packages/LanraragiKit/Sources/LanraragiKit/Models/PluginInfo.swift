import Foundation

public struct PluginInfo: Sendable, Equatable, Hashable {
    public struct Parameter: Sendable, Equatable, Hashable, Identifiable {
        public var id: String
        public var name: String?
        public var type: String?
        public var description: String?
        public var value: String?
        public var defaultValue: String?

        public init(
            id: String,
            name: String? = nil,
            type: String? = nil,
            description: String? = nil,
            value: String? = nil,
            defaultValue: String? = nil
        ) {
            self.id = id
            self.name = name
            self.type = type
            self.description = description
            self.value = value
            self.defaultValue = defaultValue
        }
    }

    public var id: String
    public var title: String
    public var description: String?
    public var oneshotArg: String?
    public var parameters: [Parameter]

    public init(
        id: String,
        title: String,
        description: String? = nil,
        oneshotArg: String? = nil,
        parameters: [Parameter] = []
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.oneshotArg = oneshotArg
        self.parameters = parameters
    }
}
