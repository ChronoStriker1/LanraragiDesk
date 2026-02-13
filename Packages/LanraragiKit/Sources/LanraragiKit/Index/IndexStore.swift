import Foundation
import SQLite3

public final class IndexStore: @unchecked Sendable {
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
