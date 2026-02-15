import Foundation

enum ReaderDirection: String, CaseIterable, Identifiable, Codable {
    case ltr
    case rtl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ltr: return "Left-to-right"
        case .rtl: return "Right-to-left"
        }
    }
}

