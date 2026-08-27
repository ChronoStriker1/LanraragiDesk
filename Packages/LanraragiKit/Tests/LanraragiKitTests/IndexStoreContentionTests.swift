import Foundation
import SQLite3
import XCTest
@testable import LanraragiKit

final class IndexStoreContentionTests: XCTestCase {
    func testBusyTimeoutIsActiveBeforeMigration() async throws {
        let fixture = try TemporaryIndexDatabase()
        defer { fixture.remove() }

        let lockingDatabase = try openDatabase(at: fixture.url)
        defer { sqlite3_close(lockingDatabase) }
        try execute(lockingDatabase, "BEGIN IMMEDIATE TRANSACTION;")
        var transactionIsOpen = true
        defer {
            if transactionIsOpen {
                try? execute(lockingDatabase, "ROLLBACK;")
            }
        }

        let state = AsyncOperationState()
        let openTask = Task.detached {
            await state.markStarted()
            do {
                let store = try IndexStore(configuration: .init(url: fixture.url))
                withExtendedLifetime(store) {}
                await state.markFinished(error: nil)
            } catch {
                await state.markFinished(error: String(describing: error))
            }
        }

        try await waitUntilStarted(state)
        try await Task.sleep(for: .milliseconds(200))
        let blockedSnapshot = await state.snapshot()
        XCTAssertFalse(blockedSnapshot.finished, "Migration should still be waiting for the writer lock")

        try execute(lockingDatabase, "COMMIT;")
        transactionIsOpen = false
        await openTask.value

        let finalSnapshot = await state.snapshot()
        XCTAssertTrue(finalSnapshot.finished)
        XCTAssertNil(finalSnapshot.error)
    }

    func testSecondStoreWriterWaitsForHeldTransaction() async throws {
        let fixture = try TemporaryIndexDatabase()
        defer { fixture.remove() }

        let firstStore = try IndexStore(configuration: .init(url: fixture.url))
        let secondStore = try IndexStore(configuration: .init(url: fixture.url))
        let profileID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        let lockingDatabase = try openDatabase(at: fixture.url)
        defer { sqlite3_close(lockingDatabase) }
        try execute(lockingDatabase, "BEGIN IMMEDIATE TRANSACTION;")
        var transactionIsOpen = true
        defer {
            if transactionIsOpen {
                try? execute(lockingDatabase, "ROLLBACK;")
            }
        }

        let state = AsyncOperationState()
        let writeTask = Task.detached {
            await state.markStarted()
            do {
                try secondStore.addNotDuplicatePair(
                    profileID: profileID,
                    arcidA: "archive-a",
                    arcidB: "archive-b"
                )
                await state.markFinished(error: nil)
            } catch {
                await state.markFinished(error: String(describing: error))
            }
        }

        try await waitUntilStarted(state)
        try await Task.sleep(for: .milliseconds(200))
        let blockedSnapshot = await state.snapshot()
        XCTAssertFalse(blockedSnapshot.finished, "The second writer should wait instead of returning SQLITE_BUSY")

        try execute(lockingDatabase, "COMMIT;")
        transactionIsOpen = false
        await writeTask.value

        let finalSnapshot = await state.snapshot()
        XCTAssertTrue(finalSnapshot.finished)
        XCTAssertNil(finalSnapshot.error)
        XCTAssertEqual(
            try firstStore.loadNotDuplicatePairs(profileID: profileID),
            [.init(arcidA: "archive-a", arcidB: "archive-b")]
        )
    }

    private func waitUntilStarted(_ state: AsyncOperationState) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await state.snapshot().started) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the concurrent operation to start")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func openDatabase(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
            if let database {
                sqlite3_close(database)
            }
            throw IndexStore.IndexStoreError.sqlite(rc: rc, message: message)
        }
        return database
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        let rc = sqlite3_exec(database, sql, nil, nil, nil)
        guard rc == SQLITE_OK else {
            throw IndexStore.IndexStoreError.sqlite(
                rc: rc,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
    }
}

private actor AsyncOperationState {
    private var started = false
    private var finished = false
    private var error: String?

    func markStarted() {
        started = true
    }

    func markFinished(error: String?) {
        finished = true
        self.error = error
    }

    func snapshot() -> (started: Bool, finished: Bool, error: String?) {
        (started, finished, error)
    }
}

private struct TemporaryIndexDatabase: Sendable {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanraragiKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("index.sqlite")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
