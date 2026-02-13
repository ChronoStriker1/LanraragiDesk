import Foundation

struct Profile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var baseURL: URL
    var language: String

    init(id: UUID = UUID(), name: String, baseURL: URL, language: String = "en-US") {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.language = language
    }
}
