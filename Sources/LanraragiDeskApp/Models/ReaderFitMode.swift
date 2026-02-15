import Foundation

enum ReaderFitMode: String, CaseIterable, Identifiable, Codable {
    case fit
    case fitWidth
    case actualSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Fit"
        case .fitWidth: return "Fit Width"
        case .actualSize: return "Actual"
        }
    }
}

