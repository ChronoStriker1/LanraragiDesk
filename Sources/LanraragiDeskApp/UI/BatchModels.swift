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
    let pluginDelayText: String
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

    struct Run: Equatable, Sendable {
        fileprivate let id: UUID
        fileprivate let intent: Intent
    }

    private(set) var activeRun: Run?
    private(set) var isCancellationRequested = false

    static func startAction(previewEnabled: Bool) -> StartAction {
        previewEnabled ? .previewThenQueue : .queueImmediately
    }

    mutating func begin(intent: Intent, id: UUID = UUID()) -> Run? {
        guard activeRun == nil else { return nil }

        let run = Run(id: id, intent: intent)
        activeRun = run
        isCancellationRequested = false
        return run
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
