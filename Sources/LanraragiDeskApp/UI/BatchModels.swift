import Foundation
import SwiftUI

// MARK: - Batch run persistence and shared state

let tagBatchCheckpointKey = "batch.tag.checkpoint.v1"
let pluginBatchCheckpointKey = "batch.plugin.checkpoint.v1"

struct TagBatchCheckpoint: Codable {
    let profileID: UUID
    let profileBaseURL: String
    let arcids: [String]
    var nextIndex: Int
    let addTagsText: String
    let removeTagsText: String
    var inProgress: Bool?
    var paused: Bool?
    var interrupted: Bool?
    var doneCount: Int?
    var errorCount: Int?
    var lastProgressText: String?
    var lastCurrentArchive: String?
    var lastErrors: [String]?
    var lastLiveEvents: [String]?
    var lastUpdatedAt: Date?
}

struct PluginBatchCheckpoint: Codable {
    let profileID: UUID
    let profileBaseURL: String
    let arcids: [String]
    var nextIndex: Int
    let selectedPluginID: String
    let pluginArgText: String
    var pluginDelayText: String
    let pluginApplyModeRaw: String
    var inProgress: Bool?
    var paused: Bool?
    var interrupted: Bool?
    var okCount: Int?
    var failCount: Int?
    var indeterminateCount: Int?
    var lastRunStatus: String?
    var lastCurrentArchive: String?
    var lastLiveEvents: [String]?
    var lastUpdatedAt: Date?
}

struct PluginBatchResumePlan {
    let checkpoint: PluginBatchCheckpoint

    init(
        checkpoint: PluginBatchCheckpoint,
        editedDelayText: String,
        resumedAt: Date = Date()
    ) {
        var updated = checkpoint
        updated.pluginDelayText = editedDelayText
        updated.inProgress = true
        updated.paused = false
        updated.interrupted = false
        let delaySeconds = PluginBatchDelayPresentation.seconds(from: editedDelayText)
        let delayDisplay = PluginBatchDelayPresentation.display(delaySeconds)
        updated.lastRunStatus = "Resuming • Active delay \(delayDisplay)s."
        updated.lastUpdatedAt = resumedAt
        self.checkpoint = updated
    }
}

enum PluginBatchDelayPresentation {
    static func seconds(from raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), parsed.isFinite else { return 0 }
        return max(0, parsed)
    }

    static func display(_ seconds: Double) -> String {
        if seconds.rounded() == seconds {
            return String(Int(seconds))
        }
        return String(format: "%.2f", seconds)
    }

    static func resumeText(delayText: String) -> String {
        "Resume will use a \(display(seconds(from: delayText)))s delay between runs."
    }
}

@MainActor
final class BatchRunState: ObservableObject {
    static let shared = BatchRunState()

    @Published var running: Bool = false
    @Published var batchCancelRequested: Bool = false
    @Published var batchPauseRequested: Bool = false
    @Published var batchPaused: Bool = false
    @Published var progressText: String?
    @Published var errors: [String] = []
    var task: Task<Void, Never>?
    @Published var batchCurrentArchive: String?
    @Published var batchLiveEvents: [String] = []

    @Published var pluginRunning: Bool = false
    @Published var pluginCancelRequested: Bool = false
    @Published var pluginPauseRequested: Bool = false
    @Published var pluginPaused: Bool = false
    @Published var pluginRunStatus: String?
    var pluginTask: Task<Void, Never>?
    @Published var pluginCurrentArchive: String?
    @Published var pluginLiveEvents: [String] = []
    @Published var liveEvents: [String] = []
}

struct BatchPreviewRow: Identifiable {
    enum Kind {
        case normal
        case error
    }

    var id: String { arcid }
    let arcid: String
    let filename: String
    let detail: String
    let kind: Kind
}

struct PluginBatchLaunch {
    let profile: Profile
    let pluginID: String
    let arcids: [String]
    let pluginArgText: String
    let pluginDelayText: String
    let pluginApplyMode: PluginApplyMode
}

enum PluginBatchPrimaryAction: Equatable {
    case queue
    case resume

    static func select(pluginPaused: Bool) -> Self {
        pluginPaused ? .resume : .queue
    }

    func title(pluginRunning: Bool) -> String {
        switch self {
        case .queue:
            return pluginRunning ? "Queueing…" : "Queue Batch"
        case .resume:
            return "Resume"
        }
    }
}

enum PluginBatchLaunchDecision: Equatable {
    case allowed
    case busy
    case settingsChanged

    static func evaluate(
        launch: PluginBatchLaunch,
        running: Bool,
        pluginRunning: Bool,
        selectedProfile: Profile?,
        selectedPluginID: String?,
        selectedArcids: [String],
        pluginArgText: String,
        pluginDelayText: String,
        pluginApplyMode: PluginApplyMode
    ) -> Self {
        guard !running, !pluginRunning else { return .busy }
        guard selectedProfile == launch.profile,
              selectedPluginID == launch.pluginID,
              selectedArcids == launch.arcids,
              pluginArgText == launch.pluginArgText,
              pluginDelayText == launch.pluginDelayText,
              pluginApplyMode == launch.pluginApplyMode else {
            return .settingsChanged
        }
        return .allowed
    }
}

enum BatchPreviewStartResult: Equatable {
    case started
    case alreadyRunning
    case unavailable

    func pluginBatchStatus(archiveCount: Int) -> String {
        switch self {
        case .started:
            return "Generating preview for \(archiveCount) archives…"
        case .alreadyRunning:
            return "Another preview is already running. Batch was not queued."
        case .unavailable:
            return "Preview could not be started. Batch was not queued."
        }
    }
}

struct BatchPreviewWorkflow {
    enum StartAction: Equatable, Sendable {
        case previewThenQueue
        case queueImmediately
    }

    enum Intent: Equatable, Sendable {
        case previewOnly
        case previewThenQueue
    }

    enum Outcome: Equatable, Sendable {
        case succeeded
        case failed
        case cancelled
    }

    enum Completion: Equatable, Sendable {
        case ignored
        case previewOnly
        case queueBatch
        case failed
        case cancelled
    }

    enum BeginResult: Equatable, Sendable {
        case started(Run)
        case alreadyRunning
    }

    struct Run: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let intent: Intent
    }

    private(set) var activeRun: Run?
    private(set) var isCancellationRequested = false

    static func startAction(previewEnabled: Bool) -> StartAction {
        previewEnabled ? .previewThenQueue : .queueImmediately
    }

    mutating func begin(intent: Intent, id: UUID = UUID()) -> BeginResult {
        guard activeRun == nil else { return .alreadyRunning }

        let run = Run(id: id, intent: intent)
        activeRun = run
        isCancellationRequested = false
        return .started(run)
    }

    func owns(_ run: Run) -> Bool {
        activeRun == run
    }

    func acceptsUpdates(from run: Run) -> Bool {
        owns(run) && !isCancellationRequested
    }

    @discardableResult
    mutating func requestCancellation() -> Bool {
        guard activeRun != nil, !isCancellationRequested else { return false }
        isCancellationRequested = true
        return true
    }

    mutating func complete(_ run: Run, outcome: Outcome) -> Completion {
        guard owns(run) else { return .ignored }

        activeRun = nil
        let wasCancelled = isCancellationRequested || outcome == .cancelled
        isCancellationRequested = false

        if wasCancelled { return .cancelled }
        if outcome == .failed { return .failed }
        return run.intent == .previewThenQueue ? .queueBatch : .previewOnly
    }
}

enum PluginApplyMode: String, CaseIterable {
    case mergeWithExisting
    case replaceWithPluginData

    var label: String {
        switch self {
        case .mergeWithExisting:
            return "Combine plugin data with existing"
        case .replaceWithPluginData:
            return "Replace current data"
        }
    }
}
