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
