import Foundation

enum ReaderNavigationDecision: Equatable {
    case page(Int)
    /// The caller can stay put or continue into the previous Tankoubon archive.
    case startOfArchive
    /// The caller can stay put or continue into the next Tankoubon archive.
    case endOfArchive
}

enum ReaderNavigationInput: Equatable {
    case toolbarLeft
    case toolbarRight
    case clickLeft
    case clickRight
    case keyboardLeft
    case keyboardRight
    case moveLeft
    case moveRight
    case space(shifted: Bool)
    case autoAdvance
}

enum ReaderNavigationAction: Equatable {
    case advance
    case retreat
}

enum ReaderNavigationDestination: Equatable {
    case page(Int)
    case archive(ReaderRoute)
    case boundary
}

enum ReaderNavigation {
    static func shouldStopAutoAdvance(
        at destination: ReaderNavigationDestination,
        userInitiated: Bool
    ) -> Bool {
        destination == .boundary && !userInitiated
    }

    static func initialIndex(
        pageCount: Int,
        twoPageSpread: Bool,
        startAtLastPage: Bool
    ) -> Int {
        guard startAtLastPage else { return 0 }
        return normalizedIndex(
            pageCount - 1,
            pageCount: pageCount,
            twoPageSpread: twoPageSpread
        )
    }

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

    static func action(
        for input: ReaderNavigationInput,
        rightToLeft: Bool
    ) -> ReaderNavigationAction {
        switch input {
        case .autoAdvance:
            return .advance
        case .space(let shifted):
            return shifted ? .retreat : .advance
        case .toolbarLeft, .clickLeft, .keyboardLeft, .moveLeft:
            return rightToLeft ? .advance : .retreat
        case .toolbarRight, .clickRight, .keyboardRight, .moveRight:
            return rightToLeft ? .retreat : .advance
        }
    }

    static func decision(
        for input: ReaderNavigationInput,
        from currentIndex: Int,
        pageCount: Int,
        twoPageSpread: Bool,
        rightToLeft: Bool
    ) -> ReaderNavigationDecision {
        switch action(for: input, rightToLeft: rightToLeft) {
        case .advance:
            return advance(
                from: currentIndex,
                pageCount: pageCount,
                twoPageSpread: twoPageSpread
            )
        case .retreat:
            return retreat(
                from: currentIndex,
                pageCount: pageCount,
                twoPageSpread: twoPageSpread
            )
        }
    }

    static func destination(
        for input: ReaderNavigationInput,
        from currentIndex: Int,
        pageCount: Int,
        twoPageSpread: Bool,
        rightToLeft: Bool,
        route: ReaderRoute,
        userInitiated: Bool
    ) -> ReaderNavigationDestination {
        let decision = decision(
            for: input,
            from: currentIndex,
            pageCount: pageCount,
            twoPageSpread: twoPageSpread,
            rightToLeft: rightToLeft
        )

        switch decision {
        case .page(let index):
            return .page(index)
        case .startOfArchive:
            guard userInitiated,
                  let tank = route.tank,
                  let previous = tank.archiveBefore(route.arcid),
                  let destination = tank.readerRoute(
                      profileID: route.profileID,
                      startingAt: previous,
                      startAtLastPage: true
                  ) else { return .boundary }
            return .archive(destination)
        case .endOfArchive:
            guard userInitiated,
                  let tank = route.tank,
                  let next = tank.archiveAfter(route.arcid),
                  let destination = tank.readerRoute(
                      profileID: route.profileID,
                      startingAt: next
                  ) else { return .boundary }
            return .archive(destination)
        }
    }
}
