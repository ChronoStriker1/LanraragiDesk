import XCTest
@testable import LanraragiKit

final class DuplicateFinderTests: XCTestCase {
    func testExactChecksumGrouping() async throws {
        let fps: [IndexStore.ScanFingerprint] = [
            .init(arcid: "a", checksumSHA256: Data([0x01]), dHashCenter90: 0, aHashCenter90: 0),
            .init(arcid: "b", checksumSHA256: Data([0x01]), dHashCenter90: 10, aHashCenter90: 10),
            .init(arcid: "c", checksumSHA256: Data([0x02]), dHashCenter90: 10, aHashCenter90: 10),
        ]

        let result = try await DuplicateFinder.scan(
            fingerprints: fps,
            notDuplicates: [],
            config: .init(includeExactChecksum: true, includeApproximate: false)
        )

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0]), Set(["a", "b"]))
        XCTAssertEqual(result.stats.exactGroups, 1)
        XCTAssertEqual(result.pairs.count, 1)
        XCTAssertEqual(Set([result.pairs[0].arcidA, result.pairs[0].arcidB]), Set(["a", "b"]))
        XCTAssertEqual(result.pairs[0].reason, .exactCover)
    }

    func testNotDuplicatesExcludesExactUnion() async throws {
        let fps: [IndexStore.ScanFingerprint] = [
            .init(arcid: "a", checksumSHA256: Data([0x01]), dHashCenter90: 0, aHashCenter90: 0),
            .init(arcid: "b", checksumSHA256: Data([0x01]), dHashCenter90: 0, aHashCenter90: 0),
        ]

        let notDup: Set<IndexStore.NotDuplicatePair> = [.init(arcidA: "a", arcidB: "b")]

        let result = try await DuplicateFinder.scan(
            fingerprints: fps,
            notDuplicates: notDup,
            config: .init(includeExactChecksum: true, includeApproximate: false)
        )

        XCTAssertEqual(result.groups.count, 0)
        XCTAssertEqual(result.pairs.count, 0)
    }

    func testApproximateUnionWithThresholds() async throws {
        // a and b differ by 1 bit in both hashes -> should link.
        let base: UInt64 = 0b1010
        let near: UInt64 = base ^ 0b0001

        let fps: [IndexStore.ScanFingerprint] = [
            .init(arcid: "a", checksumSHA256: Data([0x01]), dHashCenter90: base, aHashCenter90: base),
            .init(arcid: "b", checksumSHA256: Data([0x02]), dHashCenter90: near, aHashCenter90: near),
            .init(arcid: "c", checksumSHA256: Data([0x03]), dHashCenter90: 0xffff, aHashCenter90: 0xffff),
        ]

        let result = try await DuplicateFinder.scan(
            fingerprints: fps,
            notDuplicates: [],
            config: .init(includeExactChecksum: false, includeApproximate: true, dHashThreshold: 1, aHashThreshold: 1, bucketMaxSize: 64)
        )

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(Set(result.groups[0]), Set(["a", "b"]))
        XCTAssertEqual(result.stats.approximateEdges, 1)
        XCTAssertEqual(result.pairs.count, 1)
        XCTAssertEqual(result.pairs[0].reason, .similarCover)
    }
}
