import Foundation
import XCTest
import LanraragiKit
@testable import LanraragiDesk

@MainActor
final class LibraryListRowsCacheTests: XCTestCase {
    func testRebuildUsesMetadataAndRequestedSortOrder() {
        var cache = LibraryListRowsCache()
        let metadata = [
            "a": ArchiveMetadata(arcid: "a", title: "Zulu"),
            "b": ArchiveMetadata(arcid: "b", title: "Alpha")
        ]

        cache.rebuild(
            arcids: ["a", "b", "c"],
            metadata: metadata,
            sortOrder: [.init(\.title)]
        )

        XCTAssertEqual(cache.rows.map(\.arcid), ["b", "c", "a"])
        XCTAssertEqual(cache.rows.map(\.title), ["Alpha", "Untitled", "Zulu"])
    }

    func testMetadataUpdateRepositionsOnlyTheUpdatedRow() {
        var cache = LibraryListRowsCache()
        let sortOrder: [KeyPathComparator<LibraryListRow>] = [.init(\.title)]
        cache.rebuild(
            arcids: ["a", "b", "c"],
            metadata: [:],
            sortOrder: sortOrder
        )

        cache.updateMetadata(
            ArchiveMetadata(arcid: "b", title: "Alpha"),
            for: "b",
            sortOrder: sortOrder
        )

        XCTAssertEqual(cache.rows.map(\.arcid), ["b", "a", "c"])
        XCTAssertEqual(cache.rows.map(\.sourceIndex), [1, 0, 2])
    }

    func testMetadataUpdateUsesRequestedArcidAsCacheKey() {
        var cache = LibraryListRowsCache()
        cache.rebuild(
            arcids: ["requested"],
            metadata: [:],
            sortOrder: []
        )

        cache.updateMetadata(
            ArchiveMetadata(arcid: "server-value", title: "Loaded"),
            for: "requested",
            sortOrder: []
        )

        XCTAssertEqual(cache.rows.map(\.arcid), ["requested"])
        XCTAssertEqual(cache.rows.map(\.title), ["Loaded"])
    }

    func testEmptySortOrderKeepsSourceOrderAcrossMetadataUpdates() {
        var cache = LibraryListRowsCache()
        cache.rebuild(
            arcids: ["a", "b", "c"],
            metadata: [:],
            sortOrder: []
        )

        cache.updateMetadata(
            ArchiveMetadata(arcid: "b", title: "Loaded"),
            for: "b",
            sortOrder: []
        )

        XCTAssertEqual(cache.rows.map(\.arcid), ["a", "b", "c"])
    }

    func testRebuildReflectsAddedRemovedAndReorderedArcids() {
        var cache = LibraryListRowsCache()
        let metadata = ["b": ArchiveMetadata(arcid: "b", title: "Loaded")]
        cache.rebuild(
            arcids: ["a", "b"],
            metadata: metadata,
            sortOrder: []
        )

        cache.rebuild(
            arcids: ["b", "c"],
            metadata: metadata,
            sortOrder: []
        )

        XCTAssertEqual(cache.rows.map(\.arcid), ["b", "c"])
        XCTAssertEqual(cache.rows.map(\.title), ["Loaded", "Untitled"])
        XCTAssertEqual(cache.rows.map(\.sourceIndex), [0, 1])
    }
}
