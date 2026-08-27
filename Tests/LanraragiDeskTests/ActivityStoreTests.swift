import Foundation
import XCTest
@testable import LanraragiDesk

@MainActor
final class ActivityStoreTests: XCTestCase {
    func testFlushPersistsNewestSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = ActivityStore(fileURL: fixture.fileURL, debounceDelay: .seconds(60))
        let first = ActivityEvent(kind: .info, title: "First")
        let second = ActivityEvent(kind: .action, title: "Second")

        store.add(first)
        store.add(second)
        await store.flush()

        XCTAssertEqual(try fixture.readEvents(), [second, first])
    }

    func testClearDurablyPersistsEmptyLog() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = ActivityStore(fileURL: fixture.fileURL, debounceDelay: .seconds(60))

        store.add(ActivityEvent(kind: .warning, title: "Pending"))
        await store.clear()

        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(try fixture.readEvents(), [])
    }

    func testTerminationFlushPersistsWithoutWaitingForDebounce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = ActivityStore(fileURL: fixture.fileURL, debounceDelay: .seconds(60))
        let event = ActivityEvent(kind: .warning, title: "Before quit")

        store.add(event)
        store.flushForTermination()

        XCTAssertEqual(try fixture.readEvents(), [event])
    }

    func testPersistenceCoalescesScheduledSnapshots() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let recorder = WriteRecorder()
        let persistence = ActivityLogPersistence(
            fileURL: fixture.fileURL,
            debounceDelay: .seconds(60),
            writer: { data, _ in recorder.record(data) }
        )
        let older = ActivityEvent(kind: .info, title: "Older")
        let newest = ActivityEvent(kind: .info, title: "Newest")

        await persistence.schedule(events: [older], revision: 1)
        await persistence.schedule(events: [newest, older], revision: 2)
        try await persistence.flush(events: [newest, older], revision: 2)

        XCTAssertEqual(recorder.writeCount, 1)
        XCTAssertEqual(try recorder.events(), [newest, older])
    }

    func testOlderAsyncRequestCannotOverwriteNewerRevision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let recorder = WriteRecorder()
        let persistence = ActivityLogPersistence(
            fileURL: fixture.fileURL,
            debounceDelay: .seconds(60),
            writer: { data, _ in recorder.record(data) }
        )
        let stale = ActivityEvent(kind: .info, title: "Stale")
        let current = ActivityEvent(kind: .info, title: "Current")

        await persistence.schedule(events: [current], revision: 2)
        await persistence.schedule(events: [stale], revision: 1)
        try await persistence.flush(events: [current], revision: 2)

        XCTAssertEqual(recorder.writeCount, 1)
        XCTAssertEqual(try recorder.events(), [current])
    }
}

private final class WriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [Data] = []

    var writeCount: Int {
        lock.withLock { writes.count }
    }

    func record(_ data: Data) {
        lock.withLock {
            writes.append(data)
        }
    }

    func events() throws -> [ActivityEvent] {
        let data = lock.withLock { writes.last }
        return try JSONDecoder().decode([ActivityEvent].self, from: XCTUnwrap(data))
    }
}

private struct Fixture {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityStoreTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("activity.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func readEvents() throws -> [ActivityEvent] {
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ActivityEvent].self, from: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
