import Foundation
import LanraragiKit

// App-internal so focused tests can exercise the incremental ordering behavior
// without widening this implementation detail beyond the application module.
struct LibraryListRowsCache {
    private(set) var rows: [LibraryListRow] = []

    mutating func rebuild(
        arcids: [String],
        metadata: [String: ArchiveMetadata],
        sortOrder: [KeyPathComparator<LibraryListRow>]
    ) {
        rows = arcids.enumerated().map { sourceIndex, arcid in
            LibraryListRow(
                arcid: arcid,
                sourceIndex: sourceIndex,
                meta: metadata[arcid]
            )
        }
        sort(using: sortOrder)
    }

    mutating func updateMetadata(
        _ metadata: ArchiveMetadata?,
        for arcid: String,
        sortOrder: [KeyPathComparator<LibraryListRow>]
    ) {
        guard let oldIndex = rows.firstIndex(where: { $0.arcid == arcid }) else {
            return
        }

        let sourceIndex = rows[oldIndex].sourceIndex
        rows.remove(at: oldIndex)

        let updated = LibraryListRow(
            arcid: arcid,
            sourceIndex: sourceIndex,
            meta: metadata
        )
        let insertionIndex = insertionIndex(for: updated, sortOrder: sortOrder)
        rows.insert(updated, at: insertionIndex)
    }

    mutating func removeRow(for arcid: String) {
        rows.removeAll { $0.arcid == arcid }
    }

    mutating func sort(using sortOrder: [KeyPathComparator<LibraryListRow>]) {
        rows.sort { lhs, rhs in
            Self.precedes(lhs, rhs, sortOrder: sortOrder)
        }
    }

    private func insertionIndex(
        for row: LibraryListRow,
        sortOrder: [KeyPathComparator<LibraryListRow>]
    ) -> Int {
        var lowerBound = 0
        var upperBound = rows.count

        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if Self.precedes(rows[middle], row, sortOrder: sortOrder) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return lowerBound
    }

    private static func precedes(
        _ lhs: LibraryListRow,
        _ rhs: LibraryListRow,
        sortOrder: [KeyPathComparator<LibraryListRow>]
    ) -> Bool {
        for comparator in sortOrder {
            let result = comparator.compare(lhs, rhs)
            if result == .orderedAscending {
                return true
            }
            if result == .orderedDescending {
                return false
            }
        }

        if lhs.sourceIndex != rhs.sourceIndex {
            return lhs.sourceIndex < rhs.sourceIndex
        }
        return lhs.arcid < rhs.arcid
    }
}
