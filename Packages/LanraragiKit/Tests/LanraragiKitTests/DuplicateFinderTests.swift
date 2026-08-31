import XCTest
@testable import LanraragiKit

final class DuplicateFinderTests: XCTestCase {
    func testScanHonorsCancellationBeforeWorkBegins() async {
        let wasCancelled = await Task { () -> Bool in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }

            do {
                _ = try await DuplicateFinder.scan(
                    fingerprints: [],
                    notDuplicates: [],
                    config: .init()
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        XCTAssertTrue(wasCancelled)
    }

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

    func testSameTankoubonExcludesExactCoverPair() async throws {
        let fps: [IndexStore.ScanFingerprint] = [
            .init(arcid: "chapter-a", checksumSHA256: Data([0x01]), dHashCenter90: 0, aHashCenter90: 0),
            .init(arcid: "chapter-b", checksumSHA256: Data([0x01]), dHashCenter90: 0, aHashCenter90: 0),
        ]

        let result = try await DuplicateFinder.scan(
            fingerprints: fps,
            notDuplicates: [],
            tankoubonMemberships: [
                "chapter-a": ["TANK_series"],
                "chapter-b": ["TANK_series"],
            ],
            config: .init(includeExactChecksum: true, includeApproximate: false)
        )

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertEqual(result.stats.excludedSameTankoubon, 1)
    }

    func testSameTankoubonExcludesApproximateCoverPair() async throws {
        let base: UInt64 = 0b1010
        let near = base ^ 0b0001
        let fps: [IndexStore.ScanFingerprint] = [
            .init(arcid: "volume-a", checksumSHA256: Data([0x01]), dHashCenter90: base, aHashCenter90: base),
            .init(arcid: "volume-b", checksumSHA256: Data([0x02]), dHashCenter90: near, aHashCenter90: near),
        ]

        let result = try await DuplicateFinder.scan(
            fingerprints: fps,
            notDuplicates: [],
            tankoubonMemberships: [
                "volume-a": ["TANK_series"],
                "volume-b": ["TANK_series"],
            ],
            config: .init(includeExactChecksum: false, includeApproximate: true, dHashThreshold: 1, aHashThreshold: 1)
        )

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertEqual(result.stats.excludedSameTankoubon, 1)
        XCTAssertEqual(result.stats.approximateCandidates, 1)
    }

    func testDifferentTankoubonsRemainDuplicateCandidates() async throws {
        let fps: [IndexStore.ScanFingerprint] = [
            .init(arcid: "a", checksumSHA256: Data([0x01]), dHashCenter90: 0, aHashCenter90: 0),
            .init(arcid: "b", checksumSHA256: Data([0x01]), dHashCenter90: 0, aHashCenter90: 0),
        ]

        let result = try await DuplicateFinder.scan(
            fingerprints: fps,
            notDuplicates: [],
            tankoubonMemberships: [
                "a": ["TANK_one"],
                "b": ["TANK_two"],
            ],
            config: .init(includeExactChecksum: true, includeApproximate: false)
        )

        XCTAssertEqual(result.groups, [["a", "b"]])
        XCTAssertEqual(result.pairs.count, 1)
        XCTAssertEqual(result.stats.excludedSameTankoubon, 0)
    }

    func testExactGroupFindsAllowedPairWhenAnchorSharesDifferentTanks() async throws {
        let checksum = Data([0x01])
        let fps: [IndexStore.ScanFingerprint] = [
            .init(arcid: "anchor", checksumSHA256: checksum, dHashCenter90: 0, aHashCenter90: 0),
            .init(arcid: "chapter", checksumSHA256: checksum, dHashCenter90: 0, aHashCenter90: 0),
            .init(arcid: "volume", checksumSHA256: checksum, dHashCenter90: 0, aHashCenter90: 0),
        ]

        let result = try await DuplicateFinder.scan(
            fingerprints: fps,
            notDuplicates: [],
            tankoubonMemberships: [
                "anchor": ["TANK_chapters", "TANK_volumes"],
                "chapter": ["TANK_chapters"],
                "volume": ["TANK_volumes"],
            ],
            config: .init(
                includeExactChecksum: true,
                includeApproximate: false,
                exactFrequentMinCount: 4
            )
        )

        XCTAssertEqual(result.groups, [["chapter", "volume"]])
        XCTAssertEqual(result.pairs.count, 1)
        XCTAssertEqual(Set([result.pairs[0].arcidA, result.pairs[0].arcidB]), Set(["chapter", "volume"]))
        XCTAssertEqual(result.stats.excludedSameTankoubon, 2)
    }

    func testExactGroupKeepsAllAllowedConnectionsAroundTankoubonExclusion() async throws {
        let checksum = Data([0x01])
        let fps: [IndexStore.ScanFingerprint] = [
            .init(arcid: "chapter-a", checksumSHA256: checksum, dHashCenter90: 0, aHashCenter90: 0),
            .init(arcid: "chapter-b", checksumSHA256: checksum, dHashCenter90: 0, aHashCenter90: 0),
            .init(arcid: "outside-copy", checksumSHA256: checksum, dHashCenter90: 0, aHashCenter90: 0),
        ]

        let result = try await DuplicateFinder.scan(
            fingerprints: fps,
            notDuplicates: [],
            tankoubonMemberships: [
                "chapter-a": ["TANK_series"],
                "chapter-b": ["TANK_series"],
            ],
            config: .init(
                includeExactChecksum: true,
                includeApproximate: false,
                exactFrequentMinCount: 4
            )
        )

        XCTAssertEqual(result.groups, [["chapter-a", "chapter-b", "outside-copy"]])
        XCTAssertEqual(result.pairs.count, 2)
        XCTAssertEqual(result.stats.excludedSameTankoubon, 1)
    }

    func testExactChecksumSkipsFrequentPlaceholderCluster() async throws {
        let shared = Data([0x99])
        let other = Data([0x10])

        // 4/6 archives share one checksum; with a 50% threshold this should be treated
        // as a frequent placeholder-like checksum and skipped.
        let fps: [IndexStore.ScanFingerprint] = [
            .init(arcid: "a", checksumSHA256: shared, dHashCenter90: 1, aHashCenter90: 1),
            .init(arcid: "b", checksumSHA256: shared, dHashCenter90: 1, aHashCenter90: 1),
            .init(arcid: "c", checksumSHA256: shared, dHashCenter90: 1, aHashCenter90: 1),
            .init(arcid: "d", checksumSHA256: shared, dHashCenter90: 1, aHashCenter90: 1),
            .init(arcid: "e", checksumSHA256: other, dHashCenter90: 2, aHashCenter90: 2),
            .init(arcid: "f", checksumSHA256: Data([0x11]), dHashCenter90: 3, aHashCenter90: 3),
        ]

        let result = try await DuplicateFinder.scan(
            fingerprints: fps,
            notDuplicates: [],
            config: .init(
                includeExactChecksum: true,
                includeApproximate: false,
                exactMaxGroupSize: 20,
                exactFrequentMinCount: 3,
                exactFrequentShareThreshold: 0.5
            )
        )

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(result.pairs.isEmpty)
        XCTAssertEqual(result.stats.skippedExactGroups, 1)
    }
}
