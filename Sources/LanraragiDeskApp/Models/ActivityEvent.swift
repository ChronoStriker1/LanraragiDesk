import Foundation

struct ActivityEvent: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case info
        case warning
        case error
        case action
    }

    var id: UUID
    var date: Date
    var kind: Kind
    var title: String
    var detail: String?

    init(id: UUID = UUID(), date: Date = Date(), kind: Kind, title: String, detail: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

