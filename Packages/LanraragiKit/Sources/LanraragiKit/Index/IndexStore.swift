import Foundation
import SQLite3

public final class IndexStore: @unchecked Sendable {
    public struct ScanFingerprint: Sendable, Hashable {
        public var arcid: String
        public var checksumSHA256: Data
        public var dHashCenter90: UInt64
        public var aHashCenter90: UInt64

        public init(arcid: String, checksumSHA256: Data, dHashCenter90: UInt64, aHashCenter90: UInt64) {
            self.arcid = arcid
            self.checksumSHA256 = checksumSHA256
            self.dHashCenter90 = dHashCenter90
            self.aHashCenter90 = aHashCenter90
        }
    }

    public struct NotDuplicatePair: Sendable, Hashable {
        public var arcidA: String
        public var arcidB: String

        public init(arcidA: String, arcidB: String) {
            if arcidA <= arcidB {
                self.arcidA = arcidA
                self.arcidB = arcidB
            } else {
                self.arcidA = arcidB
                self.arcidB = arcidA
            }
        }
    }

    public struct Configuration: Sendable {
        public var url: URL

        public init(url: URL) {
            self.url = url
        }
    }

    private let config: Configuration
    private let queue = DispatchQueue(label: "LanraragiKit.IndexStore")

    private var db: OpaquePointer?

    private var stmtUpsertProfile: OpaquePointer?
    private var stmtGetHasAnyFingerprint: OpaquePointer?
    private var stmtUpsertFingerprint: OpaquePointer?
    private var stmtGetLastStart: OpaquePointer?
    private var stmtSetLastStart: OpaquePointer?
    private var stmtSelectScanFingerprints: OpaquePointer?
    private var stmtSelectNotDuplicates: OpaquePointer?
    private var stmtInsertNotDuplicate: OpaquePointer?

    public init(configuration: Configuration) throws {
        self.config = configuration

        try queue.sync {
            var db: OpaquePointer?
            try Self.open(url: configuration.url, db: &db)
            self.db = db

            guard let opened = db else {
                throw IndexStoreError.notOpen
            }

            try Self.migrate(db: opened)
            try Self.configure(db: opened)

            stmtUpsertProfile = try Self.prepare(opened, sql: """
            INSERT INTO profiles(profile_id, base_url, lang, updated_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(profile_id) DO UPDATE SET
              base_url = excluded.base_url,
              lang = excluded.lang,
              updated_at = excluded.updated_at;
            """)

            stmtGetHasAnyFingerprint = try Self.prepare(opened, sql: """
            SELECT 1 FROM fingerprints WHERE profile_id = ? AND arcid = ? LIMIT 1;
            """)

            stmtUpsertFingerprint = try Self.prepare(opened, sql: """
            INSERT INTO fingerprints(profile_id, arcid, kind, crop, hash64, aspect_ratio, thumb_checksum, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(profile_id, arcid, kind, crop) DO UPDATE SET
              hash64 = excluded.hash64,
              aspect_ratio = excluded.aspect_ratio,
              thumb_checksum = excluded.thumb_checksum,
              updated_at = excluded.updated_at;
            """)

            stmtGetLastStart = try Self.prepare(opened, sql: """
            SELECT last_start FROM index_state WHERE profile_id = ?;
            """)

            stmtSetLastStart = try Self.prepare(opened, sql: """
            INSERT INTO index_state(profile_id, last_start, last_indexed_at)
            VALUES(?, ?, ?)
            ON CONFLICT(profile_id) DO UPDATE SET
              last_start = excluded.last_start,
              last_indexed_at = excluded.last_indexed_at;
            """)

            stmtSelectScanFingerprints = try Self.prepare(opened, sql: """
            SELECT arcid, kind, crop, hash64, thumb_checksum
            FROM fingerprints
            WHERE profile_id = ?
              AND (
                (kind = 0 AND crop = 0) OR
                (kind = 0 AND crop = 1) OR
                (kind = 1 AND crop = 1)
              );
            """)

            stmtSelectNotDuplicates = try Self.prepare(opened, sql: """
            SELECT arcid_a, arcid_b
            FROM not_duplicates
            WHERE profile_id = ?;
            """)

            stmtInsertNotDuplicate = try Self.prepare(opened, sql: """
            INSERT INTO not_duplicates(profile_id, arcid_a, arcid_b, created_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(profile_id, arcid_a, arcid_b) DO NOTHING;
            """)
        }
    }

    deinit {
        queue.sync {
            [
                stmtUpsertProfile,
                stmtGetHasAnyFingerprint,
                stmtUpsertFingerprint,
                stmtGetLastStart,
                stmtSetLastStart,
                stmtSelectScanFingerprints,
                stmtSelectNotDuplicates,
                stmtInsertNotDuplicate,
            ].forEach { stmt in
                if let stmt {
                    sqlite3_finalize(stmt)
                }
            }

            if let db {
                sqlite3_close(db)
            }

            db = nil
            stmtUpsertProfile = nil
            stmtGetHasAnyFingerprint = nil
            stmtUpsertFingerprint = nil
            stmtGetLastStart = nil
            stmtSetLastStart = nil
            stmtSelectScanFingerprints = nil
            stmtSelectNotDuplicates = nil
            stmtInsertNotDuplicate = nil
        }
    }

    public func upsertProfile(profileID: UUID, baseURL: URL, language: String) throws {
        try queue.sync {
            guard let db, let stmtUpsertProfile else { throw IndexStoreError.notOpen }
            sqlite3_reset(stmtUpsertProfile)
            sqlite3_clear_bindings(stmtUpsertProfile)

            let now = Int64(Date().timeIntervalSince1970)

            try bindText(stmtUpsertProfile, index: 1, value: profileID.uuidString)
            try bindText(stmtUpsertProfile, index: 2, value: baseURL.absoluteString)
            try bindText(stmtUpsertProfile, index: 3, value: language)
            sqlite3_bind_int64(stmtUpsertProfile, 4, now)

            try stepDone(stmtUpsertProfile, db: db)
        }
    }

    public func hasAnyFingerprint(profileID: UUID, arcid: String) throws -> Bool {
        try queue.sync {
            guard let db, let stmtGetHasAnyFingerprint else { throw IndexStoreError.notOpen }
            sqlite3_reset(stmtGetHasAnyFingerprint)
            sqlite3_clear_bindings(stmtGetHasAnyFingerprint)
            defer { sqlite3_reset(stmtGetHasAnyFingerprint) } // End the read transaction promptly (WAL checkpoint friendliness).

            try bindText(stmtGetHasAnyFingerprint, index: 1, value: profileID.uuidString)
            try bindText(stmtGetHasAnyFingerprint, index: 2, value: arcid)

            let rc = sqlite3_step(stmtGetHasAnyFingerprint)
            if rc == SQLITE_ROW {
                return true
            }
            if rc == SQLITE_DONE {
                return false
            }
            throw IndexStoreError.sqlite(rc: rc, message: Self.errorMessage(db))
        }
    }

    public func upsertFingerprint(_ fp: FingerprintRecord) throws {
        try queue.sync {
            guard let db, let stmtUpsertFingerprint else { throw IndexStoreError.notOpen }
            sqlite3_reset(stmtUpsertFingerprint)
            sqlite3_clear_bindings(stmtUpsertFingerprint)

            try bindText(stmtUpsertFingerprint, index: 1, value: fp.profileID.uuidString)
            try bindText(stmtUpsertFingerprint, index: 2, value: fp.arcid)
            sqlite3_bind_int(stmtUpsertFingerprint, 3, Int32(fp.kind.rawValue))
            sqlite3_bind_int(stmtUpsertFingerprint, 4, Int32(fp.crop.rawValue))
            sqlite3_bind_int64(stmtUpsertFingerprint, 5, Int64(bitPattern: fp.hash64))
            sqlite3_bind_double(stmtUpsertFingerprint, 6, fp.aspectRatio)
            try bindBlob(stmtUpsertFingerprint, index: 7, value: fp.thumbChecksum)
            sqlite3_bind_int64(stmtUpsertFingerprint, 8, fp.updatedAt)

            try stepDone(stmtUpsertFingerprint, db: db)
        }
    }

    public func getLastStart(profileID: UUID) throws -> Int {
        try queue.sync {
            guard let db, let stmtGetLastStart else { throw IndexStoreError.notOpen }
            sqlite3_reset(stmtGetLastStart)
            sqlite3_clear_bindings(stmtGetLastStart)
            defer { sqlite3_reset(stmtGetLastStart) }

            try bindText(stmtGetLastStart, index: 1, value: profileID.uuidString)

            let rc = sqlite3_step(stmtGetLastStart)
            if rc == SQLITE_ROW {
                return Int(sqlite3_column_int(stmtGetLastStart, 0))
            }
            if rc == SQLITE_DONE {
                return 0
            }
            throw IndexStoreError.sqlite(rc: rc, message: Self.errorMessage(db))
        }
    }

    public func setLastStart(profileID: UUID, lastStart: Int) throws {
        try queue.sync {
            guard let db, let stmtSetLastStart else { throw IndexStoreError.notOpen }
            sqlite3_reset(stmtSetLastStart)
            sqlite3_clear_bindings(stmtSetLastStart)

            let now = Int64(Date().timeIntervalSince1970)

            try bindText(stmtSetLastStart, index: 1, value: profileID.uuidString)
            sqlite3_bind_int(stmtSetLastStart, 2, Int32(lastStart))
            sqlite3_bind_int64(stmtSetLastStart, 3, now)

            try stepDone(stmtSetLastStart, db: db)
        }
    }

    public func loadScanFingerprints(profileID: UUID) throws -> [ScanFingerprint] {
        try queue.sync {
            guard let db, let stmtSelectScanFingerprints else { throw IndexStoreError.notOpen }
            sqlite3_reset(stmtSelectScanFingerprints)
            sqlite3_clear_bindings(stmtSelectScanFingerprints)
            defer { sqlite3_reset(stmtSelectScanFingerprints) }

            try bindText(stmtSelectScanFingerprints, index: 1, value: profileID.uuidString)

            struct Partial {
                var checksum: Data?
                var dHashCenter90: UInt64?
                var aHashCenter90: UInt64?
            }

            var byArcid: [String: Partial] = [:]
            byArcid.reserveCapacity(60_000)

            while true {
                let rc = sqlite3_step(stmtSelectScanFingerprints)
                if rc == SQLITE_DONE { break }
                if rc != SQLITE_ROW {
                    throw IndexStoreError.sqlite(rc: rc, message: Self.errorMessage(db))
                }

                guard let arcidC = sqlite3_column_text(stmtSelectScanFingerprints, 0) else { continue }
                let arcid = String(cString: arcidC)
                let kind = Int(sqlite3_column_int(stmtSelectScanFingerprints, 1))
                let crop = Int(sqlite3_column_int(stmtSelectScanFingerprints, 2))
                let hash64 = UInt64(bitPattern: sqlite3_column_int64(stmtSelectScanFingerprints, 3))

                let blobPtr = sqlite3_column_blob(stmtSelectScanFingerprints, 4)
                let blobLen = Int(sqlite3_column_bytes(stmtSelectScanFingerprints, 4))
                let checksum: Data? = (blobPtr != nil && blobLen > 0) ? Data(bytes: blobPtr!, count: blobLen) : nil

                var p = byArcid[arcid] ?? Partial()
                if p.checksum == nil, let checksum {
                    p.checksum = checksum
                }

                if kind == FingerprintKind.dHash.rawValue, crop == FingerprintCrop.center90.rawValue {
                    p.dHashCenter90 = hash64
                } else if kind == FingerprintKind.aHash.rawValue, crop == FingerprintCrop.center90.rawValue {
                    p.aHashCenter90 = hash64
                }

                byArcid[arcid] = p
            }

            var out: [ScanFingerprint] = []
            out.reserveCapacity(byArcid.count)

            for (arcid, p) in byArcid {
                guard
                    let checksum = p.checksum,
                    let dh = p.dHashCenter90,
                    let ah = p.aHashCenter90
                else { continue }
                out.append(.init(arcid: arcid, checksumSHA256: checksum, dHashCenter90: dh, aHashCenter90: ah))
            }

            out.sort { $0.arcid < $1.arcid }
            return out
        }
    }

    public func loadNotDuplicatePairs(profileID: UUID) throws -> Set<NotDuplicatePair> {
        try queue.sync {
            guard let db, let stmtSelectNotDuplicates else { throw IndexStoreError.notOpen }
            sqlite3_reset(stmtSelectNotDuplicates)
            sqlite3_clear_bindings(stmtSelectNotDuplicates)
            defer { sqlite3_reset(stmtSelectNotDuplicates) }

            try bindText(stmtSelectNotDuplicates, index: 1, value: profileID.uuidString)

            var out = Set<NotDuplicatePair>()

            while true {
                let rc = sqlite3_step(stmtSelectNotDuplicates)
                if rc == SQLITE_DONE { break }
                if rc != SQLITE_ROW {
                    throw IndexStoreError.sqlite(rc: rc, message: Self.errorMessage(db))
                }

                guard
                    let aC = sqlite3_column_text(stmtSelectNotDuplicates, 0),
                    let bC = sqlite3_column_text(stmtSelectNotDuplicates, 1)
                else { continue }

                out.insert(.init(arcidA: String(cString: aC), arcidB: String(cString: bC)))
            }

            return out
        }
    }

    public func addNotDuplicatePair(profileID: UUID, arcidA: String, arcidB: String) throws {
        try queue.sync {
            guard let db, let stmtInsertNotDuplicate else { throw IndexStoreError.notOpen }
            sqlite3_reset(stmtInsertNotDuplicate)
            sqlite3_clear_bindings(stmtInsertNotDuplicate)

            let pair = NotDuplicatePair(arcidA: arcidA, arcidB: arcidB)
            let now = Int64(Date().timeIntervalSince1970)

            try bindText(stmtInsertNotDuplicate, index: 1, value: profileID.uuidString)
            try bindText(stmtInsertNotDuplicate, index: 2, value: pair.arcidA)
            try bindText(stmtInsertNotDuplicate, index: 3, value: pair.arcidB)
            sqlite3_bind_int64(stmtInsertNotDuplicate, 4, now)

            try stepDone(stmtInsertNotDuplicate, db: db)
        }
    }

    private static func open(url: URL, db: inout OpaquePointer?) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            throw IndexStoreError.sqlite(rc: rc, message: db.flatMap { errorMessage($0) })
        }
    }

    private static func configure(db: OpaquePointer) throws {
        try exec(db, "PRAGMA journal_mode = WAL;")
        try exec(db, "PRAGMA synchronous = NORMAL;")
        try exec(db, "PRAGMA temp_store = MEMORY;")
        try exec(db, "PRAGMA foreign_keys = ON;")

        // Keep WAL bounded; large libraries can otherwise grow the -wal file until the disk fills.
        try exec(db, "PRAGMA wal_autocheckpoint = 1000;")
        try exec(db, "PRAGMA journal_size_limit = 67108864;") // 64 MiB

        // Best-effort: shrink an existing huge WAL when opening (helps after a previous run ballooned it).
        try exec(db, "PRAGMA wal_checkpoint(TRUNCATE);")
    }

    private static func migrate(db: OpaquePointer) throws {
        try exec(db, """
        CREATE TABLE IF NOT EXISTS profiles (
          profile_id TEXT PRIMARY KEY,
          base_url TEXT NOT NULL,
          lang TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        );
        """)

        try exec(db, """
        CREATE TABLE IF NOT EXISTS fingerprints (
          profile_id TEXT NOT NULL,
          arcid TEXT NOT NULL,
          kind INTEGER NOT NULL,
          crop INTEGER NOT NULL,
          hash64 INTEGER NOT NULL,
          aspect_ratio REAL NOT NULL,
          thumb_checksum BLOB NOT NULL,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY(profile_id, arcid, kind, crop)
        );
        """)

        try exec(db, """
        CREATE TABLE IF NOT EXISTS not_duplicates (
          profile_id TEXT NOT NULL,
          arcid_a TEXT NOT NULL,
          arcid_b TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          PRIMARY KEY(profile_id, arcid_a, arcid_b)
        );
        """)

        try exec(db, """
        CREATE TABLE IF NOT EXISTS index_state (
          profile_id TEXT PRIMARY KEY,
          last_start INTEGER NOT NULL,
          last_indexed_at INTEGER NOT NULL
        );
        """)

        try exec(db, """
        CREATE INDEX IF NOT EXISTS idx_fingerprints_profile_kind_crop_hash
        ON fingerprints(profile_id, kind, crop, hash64);
        """)

        try exec(db, """
        CREATE INDEX IF NOT EXISTS idx_fingerprints_profile_checksum
        ON fingerprints(profile_id, thumb_checksum);
        """)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else {
            throw IndexStoreError.sqlite(rc: rc, message: errorMessage(db))
        }
    }

    private static func prepare(_ db: OpaquePointer, sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw IndexStoreError.sqlite(rc: rc, message: errorMessage(db))
        }
        return stmt
    }

    private func stepDone(_ stmt: OpaquePointer, db: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw IndexStoreError.sqlite(rc: rc, message: Self.errorMessage(db))
        }
    }

    private func bindText(_ stmt: OpaquePointer, index: Int32, value: String) throws {
        let rc = sqlite3_bind_text(stmt, index, value, -1, sqliteTransientDestructor)
        guard rc == SQLITE_OK else {
            throw IndexStoreError.sqlite(rc: rc, message: nil)
        }
    }

    private func bindBlob(_ stmt: OpaquePointer, index: Int32, value: Data) throws {
        let rc = value.withUnsafeBytes { buf in
            sqlite3_bind_blob(stmt, index, buf.baseAddress, Int32(buf.count), sqliteTransientDestructor)
        }
        guard rc == SQLITE_OK else {
            throw IndexStoreError.sqlite(rc: rc, message: nil)
        }
    }

    private static func errorMessage(_ db: OpaquePointer) -> String? {
        sqlite3_errmsg(db).flatMap { String(cString: $0) }
    }

    public enum IndexStoreError: Error, Sendable {
        case notOpen
        case sqlite(rc: Int32, message: String?)
    }
}

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
