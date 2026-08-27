import Foundation
import SQLite3
import XCTest
@testable import LanraragiKit

final class IndexStoreBlobBindingTests: XCTestCase {
    func testEmptyDataIsStoredAsEmptyBlob() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanraragiKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("index.sqlite")
        let store = try IndexStore(configuration: .init(url: url))
        let profileID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        try store.upsertFingerprints([
            .init(
                profileID: profileID,
                arcid: "archive",
                kind: .dHash,
                crop: .center90,
                hash64: 1,
                aspectRatio: 1.5,
                thumbChecksum: Data(),
                updatedAt: 123
            ),
        ])

        var database: OpaquePointer?
        let openRC = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openRC == SQLITE_OK, let database else {
            defer { if let database { sqlite3_close(database) } }
            XCTFail("Unable to reopen test database: \(openRC)")
            return
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepareRC = sqlite3_prepare_v2(
            database,
            "SELECT typeof(thumb_checksum), length(thumb_checksum) FROM fingerprints;",
            -1,
            &statement,
            nil
        )
        XCTAssertEqual(prepareRC, SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }

        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        let type = sqlite3_column_text(prepared, 0).map { String(cString: $0) }
        XCTAssertEqual(type, "blob")
        XCTAssertEqual(sqlite3_column_int64(prepared, 1), 0)
        withExtendedLifetime(store) {}
    }
}
