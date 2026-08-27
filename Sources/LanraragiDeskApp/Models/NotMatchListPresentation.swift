import Foundation
import LanraragiKit

@MainActor
enum NotMatchSortColumn: String, CaseIterable {
    case created
    case leftArchiveID
    case rightArchiveID

    var title: String {
        switch self {
        case .created: return "Created"
        case .leftArchiveID: return "Left archive ID"
        case .rightArchiveID: return "Right archive ID"
        }
    }

    var defaultAscending: Bool {
        switch self {
        case .created: return false
        case .leftArchiveID, .rightArchiveID: return true
        }
    }
}

@MainActor
enum NotMatchListPresentation {
    private static let createdFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let searchableDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let isoFormatter = ISO8601DateFormatter()

    static func createdDate(for pair: IndexStore.NotDuplicatePair) -> Date {
        Date(timeIntervalSince1970: Double(pair.createdAt) / 1_000)
    }

    static func createdText(for pair: IndexStore.NotDuplicatePair) -> String {
        createdFormatter.string(from: createdDate(for: pair))
    }

    static func filterAndSort(
        _ pairs: [IndexStore.NotDuplicatePair],
        query: String,
        sortColumn: NotMatchSortColumn,
        ascending: Bool
    ) -> [IndexStore.NotDuplicatePair] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)

        let filtered = tokens.isEmpty ? pairs : pairs.filter { pair in
            let date = createdDate(for: pair)
            let searchableText = [
                pair.arcidA,
                pair.arcidB,
                String(pair.createdAt),
                createdFormatter.string(from: date),
                searchableDateFormatter.string(from: date),
                isoFormatter.string(from: date)
            ]
            .joined(separator: " ")
            .lowercased()

            return tokens.allSatisfy(searchableText.contains)
        }

        return filtered.sorted { lhs, rhs in
            let primaryComparison: ComparisonResult = switch sortColumn {
            case .created:
                compare(lhs.createdAt, rhs.createdAt)
            case .leftArchiveID:
                compare(lhs.arcidA, rhs.arcidA)
            case .rightArchiveID:
                compare(lhs.arcidB, rhs.arcidB)
            }

            if primaryComparison != .orderedSame {
                return ascending
                    ? primaryComparison == .orderedAscending
                    : primaryComparison == .orderedDescending
            }

            if lhs.arcidA != rhs.arcidA { return lhs.arcidA < rhs.arcidA }
            if lhs.arcidB != rhs.arcidB { return lhs.arcidB < rhs.arcidB }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
