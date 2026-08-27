import Foundation

enum ReaderNavigationDecision: Equatable {
    case page(Int)
    /// The caller can stay put or continue into the previous Tankoubon archive.
    case startOfArchive
    /// The caller can stay put or continue into the next Tankoubon archive.
    case endOfArchive
}

enum ReaderNavigation {
    static func normalizedIndex(
        _ requestedIndex: Int,
        pageCount: Int,
        twoPageSpread: Bool
    ) -> Int {
        guard pageCount > 0 else { return 0 }

        let clampedIndex = min(max(0, requestedIndex), pageCount - 1)
        guard twoPageSpread else { return clampedIndex }
        return (clampedIndex / 2) * 2
    }

    static func advance(
        from currentIndex: Int,
        pageCount: Int,
        twoPageSpread: Bool
    ) -> ReaderNavigationDecision {
        guard pageCount > 0 else { return .endOfArchive }

        let current = normalizedIndex(
            currentIndex,
            pageCount: pageCount,
            twoPageSpread: twoPageSpread
        )
        let step = twoPageSpread ? 2 : 1
        let last = normalizedIndex(
            pageCount - 1,
            pageCount: pageCount,
            twoPageSpread: twoPageSpread
        )
        guard current < last else { return .endOfArchive }
        return .page(min(current + step, last))
    }

    static func retreat(
        from currentIndex: Int,
        pageCount: Int,
        twoPageSpread: Bool
    ) -> ReaderNavigationDecision {
        guard pageCount > 0 else { return .startOfArchive }

        let current = normalizedIndex(
            currentIndex,
            pageCount: pageCount,
            twoPageSpread: twoPageSpread
        )
        guard current > 0 else { return .startOfArchive }
        return .page(max(0, current - (twoPageSpread ? 2 : 1)))
    }
}
