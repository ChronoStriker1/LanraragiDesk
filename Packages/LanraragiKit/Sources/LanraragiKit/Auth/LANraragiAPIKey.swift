import Foundation

public struct LANraragiAPIKey: Sendable, Equatable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// LANraragi uses `Authorization: Bearer <base64(utf8(apiKey))>`.
    public var bearerHeaderValue: String {
        let data = Data(rawValue.utf8)
        return "Bearer \(data.base64EncodedString())"
    }
}
