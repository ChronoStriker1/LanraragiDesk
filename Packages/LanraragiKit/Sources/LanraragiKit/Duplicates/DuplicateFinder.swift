import Foundation

public struct DuplicateScanConfig: Sendable {
    public var includeExactChecksum: Bool
    public var includeApproximate: Bool

    public var dHashThreshold: Int
    public var aHashThreshold: Int

    /// Buckets larger than this are skipped to avoid quadratic blowups.
    public var bucketMaxSize: Int

    public init(
        includeExactChecksum: Bool = true,
        includeApproximate: Bool = true,
        dHashThreshold: Int = 6,
        aHashThreshold: Int = 6,
        bucketMaxSize: Int = 64
    ) {
        self.includeExactChecksum = includeExactChecksum
        self.includeApproximate = includeApproximate
        self.dHashThreshold = dHashThreshold
        self.aHashThreshold = aHashThreshold
        self.bucketMaxSize = bucketMaxSize
    }
}

public struct DuplicateScanStats: Sendable, Equatable {
    public var archives: Int
    public var exactGroups: Int
    public var approximateCandidates: Int
    public var approximateEdges: Int
    public var skippedBuckets: Int
    public var excludedNotDuplicates: Int
    public var durationSeconds: Double

    public init(
        archives: Int,
        exactGroups: Int,
        approximateCandidates: Int,
        approximateEdges: Int,
        skippedBuckets: Int,
        excludedNotDuplicates: Int,
        durationSeconds: Double
    ) {
        self.archives = archives
        self.exactGroups = exactGroups
        self.approximateCandidates = approximateCandidates
        self.approximateEdges = approximateEdges
        self.skippedBuckets = skippedBuckets
        self.excludedNotDuplicates = excludedNotDuplicates
        self.durationSeconds = durationSeconds
    }
}

public struct DuplicateScanResult: Sendable {
    public var groups: [[String]]
    public var stats: DuplicateScanStats

    public init(groups: [[String]], stats: DuplicateScanStats) {
        self.groups = groups
        self.stats = stats
    }
}

public enum DuplicateFinder {
    public static func scan(
        fingerprints: [IndexStore.ScanFingerprint],
        notDuplicates: Set<IndexStore.NotDuplicatePair>,
        config: DuplicateScanConfig
    ) async throws -> DuplicateScanResult {
        let started = Date()

        if fingerprints.isEmpty {
            return DuplicateScanResult(
                groups: [],
                stats: .init(
                    archives: 0,
                    exactGroups: 0,
                    approximateCandidates: 0,
                    approximateEdges: 0,
                    skippedBuckets: 0,
                    excludedNotDuplicates: 0,
                    durationSeconds: 0
                )
            )
        }

        let n = fingerprints.count
        var arcidToIndex: [String: Int] = [:]
        arcidToIndex.reserveCapacity(n)
        for (i, fp) in fingerprints.enumerated() {
            arcidToIndex[fp.arcid] = i
        }

        var excludedNotDupKeys = Set<UInt64>()
        excludedNotDupKeys.reserveCapacity(notDuplicates.count)
        for pair in notDuplicates {
            guard let a = arcidToIndex[pair.arcidA], let b = arcidToIndex[pair.arcidB], a != b else { continue }
            excludedNotDupKeys.insert(pairKey(a, b))
        }

        var dsu = DSU(count: n)

        var exactGroupCount = 0
        if config.includeExactChecksum {
            // Union identical thumbnail checksums.
            var byChecksum: [Data: Int] = [:]
            byChecksum.reserveCapacity(n)

            for (i, fp) in fingerprints.enumerated() {
                if let j = byChecksum[fp.checksumSHA256] {
                    let key = pairKey(i, j)
                    if excludedNotDupKeys.contains(key) { continue }
                    dsu.union(i, j)
                } else {
                    byChecksum[fp.checksumSHA256] = i
                }
            }

            // Stats: count checksum groups > 1.
            // This is approximate (based on first-seen map). Recount accurately:
            var counts: [Data: Int] = [:]
            counts.reserveCapacity(byChecksum.count)
            for fp in fingerprints {
                counts[fp.checksumSHA256, default: 0] += 1
            }
            exactGroupCount = counts.values.reduce(into: 0) { acc, c in if c > 1 { acc += 1 } }
        }

        var skippedBuckets = 0
        var excludedNotDuplicates = 0
        var approximateCandidates = 0
        var approximateEdges = 0

        if config.includeApproximate {
            // LSH buckets on dHashCenter90: 4 bands of 16 bits.
            var buckets: [UInt32: [Int]] = [:]
            buckets.reserveCapacity(n * 2)

            for (i, fp) in fingerprints.enumerated() {
                let h = fp.dHashCenter90
                for band in 0..<4 {
                    let key16 = UInt16((h >> (UInt64(band) * 16)) & 0xffff)
                    let bucketKey = (UInt32(band) << 16) | UInt32(key16)
                    buckets[bucketKey, default: []].append(i)
                }
            }

            var seenPairs = Set<UInt64>()
            // Heuristic reserve: if most buckets are small, we won't store many edges.
            seenPairs.reserveCapacity(n * 2)

            for (_, idxs) in buckets {
                try Task.checkCancellation()

                if idxs.count < 2 { continue }
                if idxs.count > config.bucketMaxSize {
                    skippedBuckets += 1
                    continue
                }

                for aPos in 0..<(idxs.count - 1) {
                    let ia = idxs[aPos]
                    let a = fingerprints[ia]
                    for bPos in (aPos + 1)..<idxs.count {
                        let ib = idxs[bPos]
                        if ia == ib { continue }

                        let key = pairKey(ia, ib)
                        if seenPairs.contains(key) { continue }
                        seenPairs.insert(key)

                        if excludedNotDupKeys.contains(key) {
                            excludedNotDuplicates += 1
                            continue
                        }

                        approximateCandidates += 1

                        let dDist = hamming(a.dHashCenter90, fingerprints[ib].dHashCenter90)
                        if dDist > config.dHashThreshold { continue }

                        let aDist = hamming(a.aHashCenter90, fingerprints[ib].aHashCenter90)
                        if aDist > config.aHashThreshold { continue }

                        approximateEdges += 1
                        dsu.union(ia, ib)
                    }
                }
            }
        }

        // Materialize groups (connected components).
        var groupsByRoot: [Int: [String]] = [:]
        groupsByRoot.reserveCapacity(n / 8)

        for i in 0..<n {
            let r = dsu.find(i)
            groupsByRoot[r, default: []].append(fingerprints[i].arcid)
        }

        var groups: [[String]] = []
        groups.reserveCapacity(groupsByRoot.count)
        for (_, arcids) in groupsByRoot where arcids.count > 1 {
            groups.append(arcids.sorted())
        }

        groups.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.first ?? "" < b.first ?? ""
        }

        let duration = Date().timeIntervalSince(started)
        let stats = DuplicateScanStats(
            archives: n,
            exactGroups: exactGroupCount,
            approximateCandidates: approximateCandidates,
            approximateEdges: approximateEdges,
            skippedBuckets: skippedBuckets,
            excludedNotDuplicates: excludedNotDuplicates,
            durationSeconds: duration
        )

        return DuplicateScanResult(groups: groups, stats: stats)
    }

    private static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        Int((a ^ b).nonzeroBitCount)
    }

    private static func pairKey(_ a: Int, _ b: Int) -> UInt64 {
        let lo = UInt64(min(a, b))
        let hi = UInt64(max(a, b))
        return (lo << 32) | hi
    }
}

private struct DSU {
    private var parent: [Int]
    private var size: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        size = Array(repeating: 1, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a)
        let rb = find(b)
        if ra == rb { return }

        if size[ra] < size[rb] {
            parent[ra] = rb
            size[rb] += size[ra]
        } else {
            parent[rb] = ra
            size[ra] += size[rb]
        }
    }
}

