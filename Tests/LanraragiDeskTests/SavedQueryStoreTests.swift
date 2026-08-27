import Foundation
import XCTest
@testable import LanraragiDesk

@MainActor
final class SavedQueryStoreTests: XCTestCase {
    func testMissingFileLoadsAsEmptyWithoutReportingAnError() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let store = SavedQueryStore(fileURL: fixture.fileURL)

        XCTAssertTrue(store.queries.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupURL.path))
    }

    func testCorruptFileIsBackedUpByteForByteBeforeResetting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let corruptData = Data("{ definitely-not-json".utf8)
        try corruptData.write(to: fixture.fileURL)

        let store = SavedQueryStore(fileURL: fixture.fileURL)

        XCTAssertTrue(store.queries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.backupURL), corruptData)
        XCTAssertTrue(store.errorMessage?.contains(fixture.backupURL.lastPathComponent) == true)
    }

    func testCorruptBackupDeterministicallyReplacesAnOlderBackup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("old backup".utf8).write(to: fixture.backupURL)
        let newestCorruptData = Data("[broken newest data]".utf8)
        try newestCorruptData.write(to: fixture.fileURL)

        _ = SavedQueryStore(fileURL: fixture.fileURL)

        XCTAssertEqual(try Data(contentsOf: fixture.backupURL), newestCorruptData)
    }

    func testFailedCorruptBackupBlocksWritesThatWouldDestroyOriginalData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let corruptData = Data("{ irreplaceable corrupt data".utf8)
        try corruptData.write(to: fixture.fileURL)
        try FileManager.default.createDirectory(
            at: fixture.backupURL,
            withIntermediateDirectories: false
        )
        let store = SavedQueryStore(fileURL: fixture.fileURL)

        XCTAssertThrowsError(try store.save(makeQuery(name: "Must not overwrite")))
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), corruptData)
        XCTAssertTrue(store.queries.isEmpty)
        XCTAssertTrue(store.errorMessage?.contains("could not be backed up") == true)
    }

    func testNonMissingReadFailureIsReportedWithoutCreatingCorruptBackup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.fileURL, withIntermediateDirectories: false)

        let store = SavedQueryStore(fileURL: fixture.fileURL)

        XCTAssertThrowsError(try store.save(makeQuery(name: "Must not overwrite")))
        XCTAssertTrue(store.queries.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupURL.path))
    }

    func testSaveFailureLeavesMemoryUnchangedAndReportsTheFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = SavedQueryStore(fileURL: fixture.fileURL)
        try FileManager.default.createDirectory(at: fixture.fileURL, withIntermediateDirectories: false)
        let query = makeQuery(name: "Cannot save")

        XCTAssertThrowsError(try store.save(query))
        XCTAssertTrue(store.queries.isEmpty)
        XCTAssertTrue(store.errorMessage?.contains("could not be written") == true)
    }

    func testDeleteFailureLeavesMemoryUnchangedAndReportsTheFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let query = makeQuery(name: "Keep me")
        try fixture.writeQueries([query])
        let store = SavedQueryStore(fileURL: fixture.fileURL)
        try FileManager.default.removeItem(at: fixture.fileURL)
        try FileManager.default.createDirectory(at: fixture.fileURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.delete(id: query.id))
        XCTAssertEqual(store.queries, [query])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path, isDirectory: nil))
        XCTAssertTrue(store.errorMessage?.contains("could not be written") == true)
    }

    func testSuccessfulSaveAndDeleteUpdateMemoryAndDisk() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let query = makeQuery(name: "Persist me")
        let store = SavedQueryStore(fileURL: fixture.fileURL)

        try store.save(query)
        XCTAssertEqual(store.queries, [query])
        XCTAssertEqual(try fixture.readQueries(), [query])

        try store.delete(id: query.id)
        XCTAssertTrue(store.queries.isEmpty)
        XCTAssertTrue(try fixture.readQueries().isEmpty)
    }

    private func makeQuery(name: String) -> SavedBatchQuery {
        SavedBatchQuery(
            id: UUID(uuidString: "0A30B577-EB2D-4C48-94B5-752D1503FDF7")!,
            name: name,
            profileID: UUID(uuidString: "C77E720B-CA25-44D9-A9AD-DF8A9CD726F6")!,
            conditions: [BatchQueryCondition(type: .untaggedOnly)]
        )
    }
}

private struct Fixture {
    let directoryURL: URL
    let fileURL: URL
    let backupURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("saved-batch-queries.json")
        backupURL = directoryURL.appendingPathComponent("saved-batch-queries.corrupt.json")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func writeQueries(_ queries: [SavedBatchQuery]) throws {
        try JSONEncoder().encode(queries).write(to: fileURL, options: [.atomic])
    }

    func readQueries() throws -> [SavedBatchQuery] {
        try JSONDecoder().decode([SavedBatchQuery].self, from: Data(contentsOf: fileURL))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
