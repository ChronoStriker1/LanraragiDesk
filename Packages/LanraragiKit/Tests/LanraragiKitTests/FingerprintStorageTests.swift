import Foundation
import SQLite3
import XCTest
@testable import LanraragiKit

final class FingerprintStorageTests: XCTestCase {
    func testFingerprinterOmitsCenter75Records() throws {
        let onePixelPNG = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))

        let result = try Fingerprinter.compute(from: onePixelPNG)

        XCTAssertEqual(
            result.records.map { "\($0.0.rawValue):\($0.1.rawValue)" },
            ["0:0", "1:0", "0:1", "1:1"]
        )
        XCTAssertFalse(result.records.contains { $0.1 == .center75 })
    }

    func testUpsertDoesNotPersistCenter75Records() throws {
        try withTemporaryDatabase { url in
            let store = try IndexStore(configuration: .init(url: url))
            let profileID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
            let common = (
                profileID: profileID,
                arcid: "archive",
                aspectRatio: 1.5,
                thumbChecksum: Data([0x01]),
                updatedAt: Int64(123)
            )

            try store.upsertFingerprints([
                .init(profileID: common.profileID, arcid: common.arcid, kind: .dHash, crop: .center90, hash64: 1, aspectRatio: common.aspectRatio, thumbChecksum: common.thumbChecksum, updatedAt: common.updatedAt),
                .init(profileID: common.profileID, arcid: common.arcid, kind: .aHash, crop: .center90, hash64: 2, aspectRatio: common.aspectRatio, thumbChecksum: common.thumbChecksum, updatedAt: common.updatedAt),
                .init(profileID: common.profileID, arcid: common.arcid, kind: .dHash, crop: .center75, hash64: 3, aspectRatio: common.aspectRatio, thumbChecksum: common.thumbChecksum, updatedAt: common.updatedAt),
                .init(profileID: common.profileID, arcid: common.arcid, kind: .aHash, crop: .center75, hash64: 4, aspectRatio: common.aspectRatio, thumbChecksum: common.thumbChecksum, updatedAt: common.updatedAt),
            ])

            XCTAssertEqual(try scalarInt64(url: url, sql: "SELECT COUNT(*) FROM fingerprints;"), 2)
            XCTAssertEqual(try scalarInt64(url: url, sql: "SELECT COUNT(*) FROM fingerprints WHERE crop = 2;"), 0)
            withExtendedLifetime(store) {}
        }
    }

    func testMigrationPrunesOnlyExistingCenter75Rows() throws {
        try withTemporaryDatabase { url in
            try execute(url: url, sql: """
            CREATE TABLE fingerprints (
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
            CREATE TABLE not_duplicates (
              profile_id TEXT NOT NULL,
              arcid_a TEXT NOT NULL,
              arcid_b TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              PRIMARY KEY(profile_id, arcid_a, arcid_b)
            );
            INSERT INTO fingerprints VALUES ('profile', 'archive', 0, 0, 10, 1.5, X'01', 100);
            INSERT INTO fingerprints VALUES ('profile', 'archive', 0, 1, 11, 1.5, X'01', 100);
            INSERT INTO fingerprints VALUES ('profile', 'archive', 1, 1, 12, 1.5, X'01', 100);
            INSERT INTO fingerprints VALUES ('profile', 'archive', 0, 2, 13, 1.5, X'01', 100);
            INSERT INTO fingerprints VALUES ('profile', 'archive', 1, 2, 14, 1.5, X'01', 100);
            INSERT INTO not_duplicates VALUES ('profile', 'left', 'right', 123456);
            """)

            let store = try IndexStore(configuration: .init(url: url))

            XCTAssertEqual(try scalarInt64(url: url, sql: "PRAGMA user_version;"), 1)
            XCTAssertEqual(try scalarInt64(url: url, sql: "SELECT COUNT(*) FROM fingerprints WHERE crop = 2;"), 0)
            XCTAssertEqual(try scalarInt64(url: url, sql: "SELECT COUNT(*) FROM fingerprints WHERE crop IN (0, 1);"), 3)
            XCTAssertEqual(try scalarInt64(url: url, sql: "SELECT COUNT(*) FROM not_duplicates;"), 1)
            withExtendedLifetime(store) {}
        }
    }

    private func withTemporaryDatabase(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanraragiKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("index.sqlite"))
    }

    private func execute(url: URL, sql: String) throws {
        try withSQLiteDatabase(url: url) { db in
            let rc = sqlite3_exec(db, sql, nil, nil, nil)
            guard rc == SQLITE_OK else {
                throw TestDatabaseError.sqlite(rc: rc, message: sqliteMessage(db))
            }
        }
    }

    private func scalarInt64(url: URL, sql: String) throws -> Int64 {
        try withSQLiteDatabase(url: url) { db in
            var statement: OpaquePointer?
            let prepareRC = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            guard prepareRC == SQLITE_OK, let statement else {
                throw TestDatabaseError.sqlite(rc: prepareRC, message: sqliteMessage(db))
            }
            defer { sqlite3_finalize(statement) }

            let stepRC = sqlite3_step(statement)
            guard stepRC == SQLITE_ROW else {
                throw TestDatabaseError.sqlite(rc: stepRC, message: sqliteMessage(db))
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private func withSQLiteDatabase<T>(url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let openRC = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openRC == SQLITE_OK, let database else {
            defer { if let database { sqlite3_close(database) } }
            throw TestDatabaseError.sqlite(rc: openRC, message: database.flatMap(sqliteMessage))
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func sqliteMessage(_ db: OpaquePointer) -> String? {
        sqlite3_errmsg(db).map { String(cString: $0) }
    }

    private enum TestDatabaseError: Error {
        case sqlite(rc: Int32, message: String?)
    }
}
