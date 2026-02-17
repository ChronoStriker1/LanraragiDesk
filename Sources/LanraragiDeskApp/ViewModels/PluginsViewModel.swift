import Foundation
import LanraragiKit

@MainActor
final class PluginsViewModel: ObservableObject {
    struct TrackedPluginJob: Identifiable, Equatable {
        enum State: String, Equatable {
            case queued
            case running
            case finished
            case failed
            case unknown

            var isTerminal: Bool {
                switch self {
                case .finished, .failed:
                    return true
                case .queued, .running, .unknown:
                    return false
                }
            }

            var label: String {
                switch self {
                case .queued: return "Queued"
                case .running: return "Running"
                case .finished: return "Finished"
                case .failed: return "Failed"
                case .unknown: return "Unknown"
                }
            }
        }

        var id: Int { jobID }
        let jobID: Int
        let pluginID: String
        let arcid: String
        var state: State
        var rawState: String?
        var lastUpdated: Date
        var pollCount: Int
        var lastError: String?
    }

    @Published private(set) var plugins: [PluginInfo] = []
    @Published private(set) var statusText: String?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var jobs: [TrackedPluginJob] = []
    @Published private(set) var isPollingJobs: Bool = false

    var runningCount: Int {
        jobs.filter { !$0.state.isTerminal }.count
    }

    var finishedCount: Int {
        jobs.filter { $0.state == .finished }.count
    }

    var failedCount: Int {
        jobs.filter { $0.state == .failed }.count
    }

    var hasTerminalJobs: Bool {
        jobs.contains { $0.state.isTerminal }
    }

    private var pollTask: Task<Void, Never>?
    private var jobsProfileID: Profile.ID?
    private var jobsProfile: Profile?

    func load(profile: Profile) async {
        setActiveJobsProfileIfNeeded(profile)
        isLoading = true
        statusText = "Loading plugins…"
        defer { isLoading = false }

        do {
            let client = try makeClient(profile: profile)
            plugins = try await client.listPlugins()
            statusText = plugins.isEmpty ? "No plugins found." : "Loaded \(plugins.count) plugins."
        } catch {
            statusText = "Failed: \(ErrorPresenter.short(error))"
        }
    }

    func queue(profile: Profile, pluginID: String, arcid: String, arg: String?) async throws -> MinionJob {
        setActiveJobsProfileIfNeeded(profile)
        let client = try makeClient(profile: profile)
        return try await client.queuePlugin(pluginID: pluginID, arcid: arcid, arg: arg)
    }

    func trackQueuedJob(profile: Profile, pluginID: String, arcid: String, jobID: Int) {
        guard jobID > 0 else { return }
        setActiveJobsProfileIfNeeded(profile)
        if jobs.contains(where: { $0.jobID == jobID }) {
            return
        }
        jobs.insert(.init(
            jobID: jobID,
            pluginID: pluginID,
            arcid: arcid,
            state: .queued,
            rawState: "queued",
            lastUpdated: Date(),
            pollCount: 0,
            lastError: nil
        ), at: 0)
        ensurePolling()
    }

    func refreshJobStatuses(profile: Profile) async {
        setActiveJobsProfileIfNeeded(profile)
        guard !jobs.isEmpty else { return }
        do {
            let client = try makeClient(profile: profile)
            await pollJobsOnce(client: client)
        } catch {
            statusText = "Failed to refresh jobs: \(ErrorPresenter.short(error))"
        }
    }

    func waitForJobCompletion(
        profile: Profile,
        jobID: Int,
        maxPolls: Int = 180,
        pollInterval: Duration = .seconds(1)
    ) async -> TrackedPluginJob.State {
        guard jobID > 0 else { return .finished }

        do {
            let client = try makeClient(profile: profile)
            for _ in 0..<maxPolls {
                if Task.isCancelled { return .unknown }
                do {
                    let status = try await client.getMinionStatus(job: jobID)
                    let raw = status.state ?? status.data?.state
                    let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let mapped = mapJobState(normalized: normalized)
                    update(jobID: jobID, state: mapped, rawState: raw, lastError: nil)
                    if mapped.isTerminal {
                        return mapped
                    }
                } catch let lrrError as LANraragiError {
                    switch lrrError {
                    case .httpStatus(let code, _) where code == 404 || code == 410:
                        update(jobID: jobID, state: .finished, rawState: "finished", lastError: nil)
                        return .finished
                    default:
                        update(jobID: jobID, state: .unknown, rawState: nil, lastError: ErrorPresenter.short(lrrError))
                        return .unknown
                    }
                } catch {
                    update(jobID: jobID, state: .unknown, rawState: nil, lastError: ErrorPresenter.short(error))
                    return .unknown
                }
                try? await Task.sleep(for: pollInterval)
            }
        } catch {
            statusText = "Failed to wait for job: \(ErrorPresenter.short(error))"
        }

        return .unknown
    }

    func clearTerminalJobs() {
        jobs.removeAll { $0.state.isTerminal }
    }

    private func setActiveJobsProfileIfNeeded(_ profile: Profile) {
        if jobsProfileID == profile.id {
            jobsProfile = profile
            return
        }
        pollTask?.cancel()
        pollTask = nil
        isPollingJobs = false
        jobs.removeAll()
        jobsProfileID = profile.id
        jobsProfile = profile
    }

    private func ensurePolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func pollLoop() async {
        isPollingJobs = true
        defer {
            isPollingJobs = false
            pollTask = nil
        }

        while !Task.isCancelled {
            guard jobs.contains(where: { !$0.state.isTerminal }) else { return }
            guard let profile = jobsProfile else { return }

            do {
                let client = try makeClient(profile: profile)
                await pollJobsOnce(client: client)
            } catch {
                statusText = "Failed to poll jobs: \(ErrorPresenter.short(error))"
                return
            }

            if jobs.contains(where: { !$0.state.isTerminal }) {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pollJobsOnce(client: LANraragiClient) async {
        let pending = jobs.filter { !$0.state.isTerminal }.map(\.jobID)
        guard !pending.isEmpty else { return }

        for jobID in pending {
            if Task.isCancelled { return }

            do {
                let status = try await client.getMinionStatus(job: jobID)
                apply(status: status, to: jobID)
            } catch let lrrError as LANraragiError {
                switch lrrError {
                case .httpStatus(let code, _) where code == 404 || code == 410:
                    update(jobID: jobID, state: .finished, rawState: "finished", lastError: nil)
                default:
                    update(jobID: jobID, state: .unknown, rawState: nil, lastError: ErrorPresenter.short(lrrError))
                }
            } catch {
                update(jobID: jobID, state: .unknown, rawState: nil, lastError: ErrorPresenter.short(error))
            }
        }
    }

    private func apply(status: MinionStatus, to jobID: Int) {
        let raw = status.state ?? status.data?.state
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = mapJobState(normalized: normalized)
        update(jobID: jobID, state: mapped, rawState: raw, lastError: nil)
    }

    private func mapJobState(normalized: String?) -> TrackedPluginJob.State {
        guard let normalized, !normalized.isEmpty else { return .finished }

        switch normalized {
        case "queued", "pending", "waiting", "enqueued":
            return .queued
        case "running", "processing", "active", "started":
            return .running
        case "finished", "done", "complete", "completed", "success", "succeeded", "ok":
            return .finished
        case "failed", "error", "errored", "cancelled", "canceled", "aborted", "timeout":
            return .failed
        default:
            if normalized.contains("fail") || normalized.contains("error") {
                return .failed
            }
            if normalized.contains("finish") || normalized.contains("done") || normalized.contains("success") {
                return .finished
            }
            if normalized.contains("run") || normalized.contains("process") {
                return .running
            }
            return .unknown
        }
    }

    private func update(jobID: Int, state: TrackedPluginJob.State, rawState: String?, lastError: String?) {
        guard let idx = jobs.firstIndex(where: { $0.jobID == jobID }) else { return }
        var row = jobs[idx]
        row.state = state
        row.rawState = rawState ?? row.rawState
        row.lastUpdated = Date()
        row.pollCount += 1
        row.lastError = lastError
        jobs[idx] = row
    }

    private func makeClient(profile: Profile) throws -> LANraragiClient {
        let account = "apiKey.\(profile.id.uuidString)"
        let apiKeyString = try KeychainService.getString(account: account)
        let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

        return LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: apiKey,
            acceptLanguage: profile.language,
            maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
        ))
    }
}
