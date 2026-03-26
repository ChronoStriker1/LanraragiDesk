import Foundation

enum MainPageCarouselKind: String, CaseIterable, Identifiable {
    case newArchives
    case untaggedArchives

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newArchives:
            return "New archives"
        case .untaggedArchives:
            return "Untagged archives"
        }
    }

    var subtitle: String {
        switch self {
        case .newArchives:
            return "LANraragi's New carousel"
        case .untaggedArchives:
            return "LANraragi's Untagged carousel"
        }
    }

    var searchDescription: String {
        switch self {
        case .newArchives:
            return "Show only new archives."
        case .untaggedArchives:
            return "Show only untagged archives."
        }
    }

    var isNewOnly: Bool {
        self == .newArchives
    }

    var isUntaggedOnly: Bool {
        self == .untaggedArchives
    }

    var batchConditionType: BatchQueryCondition.ConditionType {
        switch self {
        case .newArchives:
            return .newOnly
        case .untaggedArchives:
            return .untaggedOnly
        }
    }
}
