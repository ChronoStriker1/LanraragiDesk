import Foundation
import LanraragiKit
import XCTest
@testable import LanraragiDesk

final class BatchPreviewWorkflowTests: XCTestCase {
    private enum TestError: Error {
        case workflowDidNotStart
    }

    func testPreviewSettingSelectsExpectedStartAction() {
        XCTAssertEqual(BatchPreviewWorkflow.startAction(previewEnabled: true), .previewThenQueue)
        XCTAssertEqual(BatchPreviewWorkflow.startAction(previewEnabled: false), .queueImmediately)
    }

    func testPluginBatchPrimaryActionReplacesQueueOnlyWhilePaused() {
        let queue = PluginBatchPrimaryAction.select(pluginPaused: false)
        XCTAssertEqual(queue, .queue)
        XCTAssertEqual(queue.title(pluginRunning: false), "Queue Batch")
        XCTAssertEqual(queue.title(pluginRunning: true), "Queueing…")

        let resume = PluginBatchPrimaryAction.select(pluginPaused: true)
        XCTAssertEqual(resume, .resume)
        XCTAssertEqual(resume.title(pluginRunning: false), "Resume")
        XCTAssertEqual(resume.title(pluginRunning: true), "Resume")
    }

    func testPluginBatchResumePlanAppliesEditedDelayWithoutChangingCheckpointProgress() {
        let checkpoint = pluginCheckpoint(
            nextIndex: 2,
            delayText: "4",
            ok: 1,
            fail: 1,
            indeterminate: 0
        )
        let resumedAt = Date(timeIntervalSince1970: 2_000)

        let resumed = PluginBatchResumePlan(
            checkpoint: checkpoint,
            editedDelayText: "0.75",
            resumedAt: resumedAt
        ).checkpoint

        XCTAssertEqual(resumed.pluginDelayText, "0.75")
        XCTAssertEqual(resumed.nextIndex, 2)
        XCTAssertEqual(resumed.arcids, checkpoint.arcids)
        XCTAssertEqual(resumed.selectedPluginID, checkpoint.selectedPluginID)
        XCTAssertEqual(resumed.pluginArgText, checkpoint.pluginArgText)
        XCTAssertEqual(resumed.pluginApplyModeRaw, checkpoint.pluginApplyModeRaw)
        XCTAssertEqual(resumed.inProgress, true)
        XCTAssertEqual(resumed.paused, false)
        XCTAssertEqual(resumed.interrupted, false)
        XCTAssertEqual(resumed.okCount, 1)
        XCTAssertEqual(resumed.failCount, 1)
        XCTAssertEqual(resumed.indeterminateCount, 0)
        XCTAssertEqual(resumed.lastRunStatus, "Resuming • Active delay 0.75s.")
        XCTAssertEqual(resumed.lastUpdatedAt, resumedAt)
    }

    func testPluginBatchDelayStatusUsesSanitizedEditedValue() {
        XCTAssertEqual(
            PluginBatchDelayPresentation.resumeText(delayText: " 1.25 "),
            "Resume will use a 1.25s delay between runs."
        )
        XCTAssertEqual(PluginBatchDelayPresentation.seconds(from: "-3"), 0)
        XCTAssertEqual(PluginBatchDelayPresentation.seconds(from: "not a number"), 0)
    }

    func testSuccessfulPreviewThenQueueQueuesExactlyOnce() throws {
        var workflow = BatchPreviewWorkflow()
        let run = try startedRun(workflow.begin(intent: .previewThenQueue, id: UUID()))

        XCTAssertEqual(workflow.complete(run, outcome: .succeeded), .queueBatch)
        XCTAssertEqual(workflow.complete(run, outcome: .succeeded), .ignored)
        XCTAssertNil(workflow.activeRun)
    }

    func testPreviewOnlyNeverQueues() throws {
        var workflow = BatchPreviewWorkflow()
        let run = try startedRun(workflow.begin(intent: .previewOnly, id: UUID()))

        XCTAssertEqual(workflow.complete(run, outcome: .succeeded), .previewOnly)
    }

    func testFailedPreviewDoesNotQueue() throws {
        var workflow = BatchPreviewWorkflow()
        let run = try startedRun(workflow.begin(intent: .previewThenQueue, id: UUID()))

        XCTAssertEqual(workflow.complete(run, outcome: .failed), .failed)
        XCTAssertNil(workflow.activeRun)
    }

    func testCancellationStaysOwnedUntilTaskFinishesAndDoesNotQueue() throws {
        var workflow = BatchPreviewWorkflow()
        let run = try startedRun(workflow.begin(intent: .previewThenQueue, id: UUID()))

        XCTAssertTrue(workflow.requestCancellation())
        XCTAssertTrue(workflow.owns(run))
        XCTAssertFalse(workflow.acceptsUpdates(from: run))
        XCTAssertEqual(workflow.begin(intent: .previewThenQueue, id: UUID()), .alreadyRunning)
        XCTAssertEqual(workflow.complete(run, outcome: .succeeded), .cancelled)
        XCTAssertNil(workflow.activeRun)
    }

    func testTaskCancellationDoesNotQueueWithoutExplicitRequest() throws {
        var workflow = BatchPreviewWorkflow()
        let run = try startedRun(workflow.begin(intent: .previewThenQueue, id: UUID()))

        XCTAssertEqual(workflow.complete(run, outcome: .cancelled), .cancelled)
    }

    func testPreviewStartResultProvidesExplicitStatusForEveryDecision() {
        XCTAssertEqual(
            BatchPreviewStartResult.started.pluginBatchStatus(archiveCount: 4),
            "Generating preview for 4 archives…"
        )
        XCTAssertEqual(
            BatchPreviewStartResult.alreadyRunning.pluginBatchStatus(archiveCount: 4),
            "Another preview is already running. Batch was not queued."
        )
        XCTAssertEqual(
            BatchPreviewStartResult.unavailable.pluginBatchStatus(archiveCount: 4),
            "Preview could not be started. Batch was not queued."
        )
    }

    func testPluginBatchLaunchValidationAllowsUnchangedIdleLaunch() {
        let fixture = launchFixture()

        XCTAssertEqual(evaluate(fixture.launch, fixture: fixture), .allowed)
    }

    func testPluginBatchLaunchValidationRejectsEitherBusyState() {
        let fixture = launchFixture()

        XCTAssertEqual(evaluate(fixture.launch, fixture: fixture, running: true), .busy)
        XCTAssertEqual(evaluate(fixture.launch, fixture: fixture, pluginRunning: true), .busy)
    }

    func testPluginBatchLaunchValidationRejectsEveryChangedSetting() {
        let fixture = launchFixture()
        let otherProfile = Profile(name: "Other", baseURL: URL(string: "https://other.example")!)

        XCTAssertEqual(evaluate(fixture.launch, fixture: fixture, selectedProfile: otherProfile), .settingsChanged)
        XCTAssertEqual(evaluate(fixture.launch, fixture: fixture, selectedPluginID: "different"), .settingsChanged)
        XCTAssertEqual(evaluate(fixture.launch, fixture: fixture, selectedArcids: ["other"]), .settingsChanged)
        XCTAssertEqual(evaluate(fixture.launch, fixture: fixture, pluginArgText: "different"), .settingsChanged)
        XCTAssertEqual(evaluate(fixture.launch, fixture: fixture, pluginDelayText: "different"), .settingsChanged)
        XCTAssertEqual(evaluate(
            fixture.launch,
            fixture: fixture,
            pluginApplyMode: .replaceWithPluginData
        ), .settingsChanged)
    }

    @MainActor
    func testQueuedMetadataPatchUsesSelectedBatchApplyMode() {
        let view = BatchView()
        let patch = PluginMetadataPatch(
            title: "Plugin title",
            tags: "artist:New, language:English",
            summary: "Plugin summary"
        )

        let merged = view.applyPluginPatch(
            patch,
            currentTitle: "Old title",
            currentTags: "artist:Old, language:English",
            currentSummary: "Old summary",
            mode: .mergeWithExisting
        )
        let replaced = view.applyPluginPatch(
            patch,
            currentTitle: "Old title",
            currentTags: "artist:Old, language:English",
            currentSummary: "Old summary",
            mode: .replaceWithPluginData
        )

        XCTAssertEqual(merged.title, "Plugin title")
        XCTAssertEqual(merged.tags, "artist:Old, language:English, artist:New")
        XCTAssertEqual(merged.summary, "Plugin summary")
        XCTAssertEqual(replaced.title, "Plugin title")
        XCTAssertEqual(replaced.tags, "artist:New, language:English")
        XCTAssertEqual(replaced.summary, "Plugin summary")
    }

    private func startedRun(
        _ result: BatchPreviewWorkflow.BeginResult
    ) throws -> BatchPreviewWorkflow.Run {
        guard case .started(let run) = result else {
            XCTFail("Expected workflow to start")
            throw TestError.workflowDidNotStart
        }
        return run
    }

    private typealias LaunchFixture = (
        launch: PluginBatchLaunch,
        profile: Profile,
        pluginID: String,
        arcids: [String],
        pluginArgText: String,
        pluginDelayText: String,
        pluginApplyMode: PluginApplyMode
    )

    private func launchFixture() -> LaunchFixture {
        let profile = Profile(name: "Test", baseURL: URL(string: "https://example.test")!)
        let pluginID = "plugin"
        let arcids = ["a", "b"]
        let pluginArgText = "argument"
        let pluginDelayText = "2"
        let pluginApplyMode = PluginApplyMode.mergeWithExisting
        return (
            PluginBatchLaunch(
                profile: profile,
                pluginID: pluginID,
                arcids: arcids,
                pluginArgText: pluginArgText,
                pluginDelayText: pluginDelayText,
                pluginApplyMode: pluginApplyMode
            ),
            profile,
            pluginID,
            arcids,
            pluginArgText,
            pluginDelayText,
            pluginApplyMode
        )
    }

    private func pluginCheckpoint(
        nextIndex: Int,
        delayText: String,
        ok: Int,
        fail: Int,
        indeterminate: Int
    ) -> PluginBatchCheckpoint {
        PluginBatchCheckpoint(
            profileID: UUID(),
            profileBaseURL: "https://example.test",
            arcids: ["a", "b", "c", "d"],
            nextIndex: nextIndex,
            selectedPluginID: "plugin",
            pluginArgText: "argument",
            pluginDelayText: delayText,
            pluginApplyModeRaw: PluginApplyMode.mergeWithExisting.rawValue,
            inProgress: true,
            paused: true,
            interrupted: false,
            okCount: ok,
            failCount: fail,
            indeterminateCount: indeterminate,
            lastRunStatus: "Paused",
            lastCurrentArchive: "b",
            lastLiveEvents: ["Processed b"],
            lastUpdatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func evaluate(
        _ launch: PluginBatchLaunch,
        fixture: LaunchFixture,
        running: Bool = false,
        pluginRunning: Bool = false,
        selectedProfile: Profile? = nil,
        selectedPluginID: String? = nil,
        selectedArcids: [String]? = nil,
        pluginArgText: String? = nil,
        pluginDelayText: String? = nil,
        pluginApplyMode: PluginApplyMode? = nil
    ) -> PluginBatchLaunchDecision {
        PluginBatchLaunchDecision.evaluate(
            launch: launch,
            running: running,
            pluginRunning: pluginRunning,
            selectedProfile: selectedProfile ?? fixture.profile,
            selectedPluginID: selectedPluginID ?? fixture.pluginID,
            selectedArcids: selectedArcids ?? fixture.arcids,
            pluginArgText: pluginArgText ?? fixture.pluginArgText,
            pluginDelayText: pluginDelayText ?? fixture.pluginDelayText,
            pluginApplyMode: pluginApplyMode ?? fixture.pluginApplyMode
        )
    }
}
