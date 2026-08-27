import Foundation

enum LibraryRequestTimingCategory: String, CaseIterable, Sendable {
    case search
    case archivePage
    case metadata

    var title: String {
        switch self {
        case .search: return "Search"
        case .archivePage: return "Archive page"
        case .metadata: return "Metadata"
        }
    }
}

enum LibraryRequestTimingOperation: String, CaseIterable, Sendable {
    case search
    case archivePage
    case metadataRefresh
    case metadataUpdate

    var category: LibraryRequestTimingCategory {
        switch self {
        case .search: return .search
        case .archivePage: return .archivePage
        case .metadataRefresh, .metadataUpdate: return .metadata
        }
    }

    var title: String {
        switch self {
        case .search: return "Search"
        case .archivePage: return "Archive page"
        case .metadataRefresh: return "Metadata refresh"
        case .metadataUpdate: return "Metadata update"
        }
    }
}

enum LibraryRequestTimingOutcome: String, CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled

    var title: String {
        switch self {
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

struct LibraryRequestTiming: Identifiable, Equatable, Sendable {
    let id: UUID
    let operation: LibraryRequestTimingOperation
    let duration: Duration
    let outcome: LibraryRequestTimingOutcome
    let completedAt: Date

    var category: LibraryRequestTimingCategory { operation.category }

    init(
        id: UUID = UUID(),
        operation: LibraryRequestTimingOperation,
        duration: Duration,
        outcome: LibraryRequestTimingOutcome,
        completedAt: Date = Date()
    ) {
        self.id = id
        self.operation = operation
        self.duration = duration
        self.outcome = outcome
        self.completedAt = completedAt
    }
}

struct LibraryRequestTimingHistory: Equatable, Sendable {
    let capacity: Int
    private(set) var entries: [LibraryRequestTiming] = []

    init(capacity: Int = 12) {
        self.capacity = max(1, capacity)
    }

    mutating func record(_ timing: LibraryRequestTiming) {
        entries.insert(timing, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }
}

enum LibraryRequestTimingFormatter {
    static func duration(_ duration: Duration) -> String {
        let components = duration.components
        let rawSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let seconds = max(0, rawSeconds)

        if seconds < 1 {
            return "\(Int((seconds * 1_000).rounded())) ms"
        }
        if seconds < 10 {
            return String(format: "%.2f s", seconds)
        }
        if seconds < 60 {
            return String(format: "%.1f s", seconds)
        }

        let minutes = Int(seconds) / 60
        let remainingSeconds = seconds - Double(minutes * 60)
        return String(format: "%dm %.1f s", minutes, remainingSeconds)
    }
}
