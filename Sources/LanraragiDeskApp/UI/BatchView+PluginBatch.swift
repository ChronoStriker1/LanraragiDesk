import Foundation
import SwiftUI
import LanraragiKit

// MARK: - Plugin batch run engine

extension BatchView {
    func loadPlugins() async {
        guard let profile = appModel.selectedProfile else { return }
        await pluginsVM.load(profile: profile)
        if let selectedPluginID, pluginsVM.plugins.contains(where: { $0.id == selectedPluginID }) {
            applyDefaultPluginDelayFromSelection()
            return
        }
        selectedPluginID = pluginsVM.plugins.first?.id
        applyDefaultPluginDelayFromSelection()
    }

    func runPluginBatch() {
        guard let profile = appModel.selectedProfile else { return }
        guard let pluginID = selectedPluginID else { return }
        let arcids = selectedArcidsSorted
        guard !arcids.isEmpty else { return }

        let launch = PluginBatchLaunch(
            profile: profile,
            pluginID: pluginID,
            arcids: arcids,
            pluginArgText: pluginArgText,
            pluginDelayText: pluginDelayText,
            pluginApplyMode: pluginApplyMode
        )

        switch BatchPreviewWorkflow.startAction(previewEnabled: previewBeforeQueue) {
        case .previewThenQueue:
            let startResult = generatePreview(
                executePlugin: true,
                purpose: .previewThenQueue,
                pendingBatch: launch
            )
            pluginRunStatus = startResult.pluginBatchStatus(archiveCount: arcids.count)
            if startResult == .started {
                appendPluginLiveEvent("Preview started for \(pluginID) on \(arcids.count) archives")
            }
            return
        case .queueImmediately:
            queuePluginBatch(launch)
        }
    }

    func queuePluginBatch(_ launch: PluginBatchLaunch) {
        let decision = PluginBatchLaunchDecision.evaluate(
            launch: launch,
            running: running,
            pluginRunning: pluginRunning,
            selectedProfile: appModel.selectedProfile,
            selectedPluginID: selectedPluginID,
            selectedArcids: selectedArcidsSorted,
            pluginArgText: pluginArgText,
            pluginDelayText: pluginDelayText,
            pluginApplyMode: pluginApplyMode
        )
        switch decision {
        case .busy:
            pluginRunStatus = "Another batch is already running. Batch was not queued."
            return
        case .settingsChanged:
            pluginRunStatus = "Preview settings changed. Batch was not queued."
            return
        case .allowed:
            break
        }

        let checkpoint = PluginBatchCheckpoint(
            profileID: launch.profile.id,
            profileBaseURL: launch.profile.baseURL.absoluteString,
            arcids: launch.arcids,
            nextIndex: 0,
            selectedPluginID: launch.pluginID,
            pluginArgText: launch.pluginArgText,
            pluginDelayText: launch.pluginDelayText,
            pluginApplyModeRaw: launch.pluginApplyMode.rawValue,
            inProgress: true,
            paused: false,
            interrupted: false,
            okCount: 0,
            failCount: 0,
            indeterminateCount: 0,
            lastRunStatus: "Running plugin on \(launch.arcids.count) archives…",
            lastCurrentArchive: nil,
            lastLiveEvents: [],
            lastUpdatedAt: Date()
        )
        savePluginBatchCheckpoint(checkpoint)
        refreshResumablePluginBatch()

        startPluginBatch(
            profile: launch.profile,
            pluginID: launch.pluginID,
            pluginArgument: launch.pluginArgText,
            delayText: launch.pluginDelayText,
            arcids: launch.arcids,
            startIndex: 0,
            resumed: false
        )
    }

    func startPluginBatch(
        profile: Profile,
        pluginID: String,
        pluginArgument: String,
        delayText: String,
        arcids: [String],
        startIndex: Int,
        resumed: Bool,
        initialOK: Int = 0,
        initialFail: Int = 0,
        initialIndeterminate: Int = 0
    ) {
        let delaySeconds = sanitizedDelaySeconds(from: delayText)

        pluginRunning = true
        pluginCancelRequested = false
        pluginPauseRequested = false
        pluginPaused = false
        pluginCurrentArchive = nil
        if !resumed {
            pluginLiveEvents = []
        }
        if resumed {
            let startHuman = min(max(startIndex + 1, 1), max(arcids.count, 1))
            let activeDelay = delayDisplay(delaySeconds)
            pluginRunStatus = "Resumed \(pluginID) at archive \(startHuman)/\(arcids.count) • Active delay \(activeDelay)s."
            appendPluginLiveEvent("Resumed \(pluginID) at \(startHuman)/\(arcids.count) with \(activeDelay)s delay")
            appModel.activity.add(.init(
                kind: .action,
                title: "Plugin batch resumed",
                detail: "\(pluginID) at \(startHuman)/\(arcids.count) • \(activeDelay)s delay"
            ))
        } else {
            pluginRunStatus = "Running plugin on \(arcids.count) archives…"
            appModel.activity.add(.init(kind: .action, title: "Plugin batch queued", detail: "\(pluginID) on \(arcids.count) archives"))
            appendPluginLiveEvent("Started \(pluginID) on \(arcids.count) archives")
        }

        pluginTask?.cancel()
        pluginTask = Task {
            var ok = initialOK
            var fail = initialFail
            var indeterminate = initialIndeterminate
            for index in startIndex..<arcids.count {
                let arcid = arcids[index]
                if await MainActor.run(body: { pluginCancelRequested || pluginPauseRequested }) { break }
                await MainActor.run {
                    pluginCurrentArchive = displayName(for: arcid)
                    appendPluginLiveEvent("Processing \(displayName(for: arcid))")
                }

                persistPluginCheckpointIndexAndUI(
                    pluginID: pluginID,
                    nextIndex: index,
                    ok: ok,
                    fail: fail,
                    indeterminate: indeterminate,
                    total: arcids.count
                )

                do {
                    let prePluginMeta = try? await appModel.archives.metadata(profile: profile, arcid: arcid, forceRefresh: true)
                    let preSignature = prePluginMeta.map {
                        PluginMetadataSupport.signature(title: $0.title ?? "", tags: $0.tags ?? "", summary: $0.summary ?? "")
                    }

                    let job = try await pluginsVM.queue(profile: profile, pluginID: pluginID, arcid: arcid, arg: pluginArgument)
                    pluginsVM.trackQueuedJob(profile: profile, pluginID: pluginID, arcid: arcid, jobID: job.job)
                    let detail = job.job > 0
                        ? "\(pluginID) • \(arcid) • job \(job.job)"
                        : "\(pluginID) • \(arcid) • executed (no job id returned)"
                    appModel.activity.add(.init(kind: .action, title: "Plugin job queued", detail: detail))
                    await MainActor.run {
                        if job.job > 0 {
                            appendPluginLiveEvent("Queued job \(job.job) for \(displayName(for: arcid))")
                        } else {
                            appendPluginLiveEvent("Ran without job id for \(displayName(for: arcid))")
                        }
                    }

                    if job.job > 0 {
                        let state = await pluginsVM.waitForJobCompletion(profile: profile, jobID: job.job)
                        switch state {
                        case .failed:
                            fail += 1
                            appModel.activity.add(.init(kind: .warning, title: "Plugin job failed", detail: "\(pluginID) • \(arcid) • job \(job.job)"))
                            await MainActor.run {
                                appendPluginLiveEvent("Job \(job.job) failed for \(displayName(for: arcid))")
                            }
                        case .finished:
                            // The queued plugin already ran. Minion status has no output payload,
                            // so only refresh metadata here; calling `run` would execute it again.
                            let changed = await refreshMetadataAfterPluginBatch(profile: profile, arcid: arcid, previousSignature: preSignature)
                            if !changed {
                                appModel.activity.add(.init(
                                    kind: .action,
                                    title: "Plugin completed with no metadata changes",
                                    detail: "\(pluginID) • \(arcid) • queued job output unavailable"
                                ))
                            }
                            if let before = prePluginMeta {
                                let latest = try? await appModel.archives.metadata(profile: profile, arcid: arcid, forceRefresh: true)
                                if let latest {
                                    await MainActor.run {
                                        appendPluginLiveEvent(metadataChangeLiveMessage(
                                            prefix: "Saved",
                                            arcid: arcid,
                                            beforeTitle: before.title ?? "",
                                            beforeTags: before.tags ?? "",
                                            beforeSummary: before.summary ?? "",
                                            afterTitle: latest.title ?? "",
                                            afterTags: latest.tags ?? "",
                                            afterSummary: latest.summary ?? ""
                                        ))
                                    }
                                }
                            }
                            ok += 1
                            await MainActor.run {
                                appendPluginLiveEvent("Finished \(displayName(for: arcid))")
                            }
                        case .queued, .running, .unknown:
                            indeterminate += 1
                            _ = await refreshMetadataAfterPluginBatch(
                                profile: profile,
                                arcid: arcid,
                                previousSignature: preSignature
                            )
                            appModel.activity.add(.init(
                                kind: .warning,
                                title: "Plugin job outcome indeterminate",
                                detail: "\(pluginID) • \(arcid) • job \(job.job) • \(state.rawValue)"
                            ))
                            await MainActor.run {
                                appendPluginLiveEvent("Job \(job.job) outcome unknown for \(displayName(for: arcid)); not counted as success")
                            }
                        }
                    } else {
                        let changed = await refreshMetadataAfterPluginBatch(profile: profile, arcid: arcid, previousSignature: preSignature)
                        if !changed {
                            appModel.activity.add(.init(
                                kind: .action,
                                title: "Plugin completed with no metadata changes",
                                detail: "\(pluginID) • \(arcid) • no trackable job output"
                            ))
                        }
                        if let before = prePluginMeta {
                            let latest = try? await appModel.archives.metadata(profile: profile, arcid: arcid, forceRefresh: true)
                            if let latest {
                                await MainActor.run {
                                    appendPluginLiveEvent(metadataChangeLiveMessage(
                                        prefix: "Saved",
                                        arcid: arcid,
                                        beforeTitle: before.title ?? "",
                                        beforeTags: before.tags ?? "",
                                        beforeSummary: before.summary ?? "",
                                        afterTitle: latest.title ?? "",
                                        afterTags: latest.tags ?? "",
                                        afterSummary: latest.summary ?? ""
                                    ))
                                }
                            }
                        }
                        ok += 1
                        await MainActor.run {
                            appendPluginLiveEvent("Finished \(displayName(for: arcid))")
                        }
                    }
                } catch {
                    fail += 1
                    appModel.activity.add(.init(kind: .error, title: "Plugin queue failed", detail: "\(pluginID) • \(arcid)\n\(error)"))
                    await MainActor.run {
                        appendPluginLiveEvent("Failed \(displayName(for: arcid)): \(ErrorPresenter.short(error))")
                    }
                }
                await MainActor.run {
                    pluginRunStatus = "Processed \(index + 1)/\(arcids.count) • Success \(ok) • Failed \(fail) • Indeterminate \(indeterminate)…"
                }
                persistPluginCheckpointIndexAndUI(
                    pluginID: pluginID,
                    nextIndex: index + 1,
                    ok: ok,
                    fail: fail,
                    indeterminate: indeterminate,
                    total: arcids.count
                )

                if await MainActor.run(body: { pluginPauseRequested }) {
                    if let existing = loadPluginBatchCheckpoint() {
                        var updated = existing
                        // The current archive completed before the pause took effect.
                        updated.nextIndex = min(index + 1, arcids.count)
                        updated.paused = true
                        updated.inProgress = true
                        updated.interrupted = false
                        updated.okCount = ok
                        updated.failCount = fail
                        updated.indeterminateCount = indeterminate
                        updated.lastRunStatus = pluginRunStatus
                        updated.lastCurrentArchive = pluginCurrentArchive
                        updated.lastLiveEvents = trimmedCheckpointEvents(pluginLiveEvents)
                        updated.lastUpdatedAt = Date()
                        savePluginBatchCheckpoint(updated)
                    }
                    break
                }

                if index + 1 < arcids.count && delaySeconds > 0 {
                    if await pauseBetweenPluginRuns(
                        seconds: delaySeconds,
                        done: index + 1,
                        total: arcids.count,
                        ok: ok,
                        fail: fail,
                        indeterminate: indeterminate
                    ) {
                        break
                    }
                }
            }

            let cancelledByRequest = await MainActor.run { pluginCancelRequested }
            let pausedByRequest = await MainActor.run { pluginPauseRequested }

            await MainActor.run {
                pluginRunning = false
                pluginCurrentArchive = nil
                if pausedByRequest {
                    pluginRunStatus = "Paused. Success \(ok), failed \(fail), indeterminate \(indeterminate)."
                    pluginPaused = true
                } else if cancelledByRequest {
                    pluginRunStatus = "Cancelled. Success \(ok), failed \(fail), indeterminate \(indeterminate)."
                } else {
                    pluginRunStatus = "Done. Success \(ok), failed \(fail), indeterminate \(indeterminate)."
                }
                pluginCancelRequested = false
                pluginPauseRequested = false
                pluginTask = nil
            }

            if pausedByRequest {
                appModel.activity.add(.init(kind: .warning, title: "Plugin batch paused", detail: "\(pluginID)"))
                persistPluginCheckpointUI(
                    pluginID: pluginID,
                    inProgress: true,
                    paused: true,
                    interrupted: false,
                    ok: ok,
                    fail: fail,
                    indeterminate: indeterminate
                )
                await MainActor.run {
                    refreshResumablePluginBatch()
                }
            } else if cancelledByRequest {
                persistPluginCheckpointUI(
                    pluginID: pluginID,
                    inProgress: false,
                    paused: false,
                    interrupted: false,
                    ok: ok,
                    fail: fail,
                    indeterminate: indeterminate
                )
                clearPluginBatchCheckpoint()
                await MainActor.run {
                    refreshResumablePluginBatch()
                }
                appModel.activity.add(.init(kind: .warning, title: "Plugin batch cancelled", detail: "\(pluginID)"))
            } else {
                persistPluginCheckpointUI(
                    pluginID: pluginID,
                    inProgress: false,
                    paused: false,
                    interrupted: false,
                    ok: ok,
                    fail: fail,
                    indeterminate: indeterminate
                )
                clearPluginBatchCheckpoint()
                await MainActor.run {
                    refreshResumablePluginBatch()
                }
            }
        }
    }

    func requestPluginCancel() {
        guard pluginRunning, !pluginCancelRequested else { return }
        pluginCancelRequested = true
        pluginRunStatus = "Stopping after current archive operation finishes…"
        persistPluginCheckpointUI(
            pluginID: selectedPluginID ?? "",
            inProgress: true,
            paused: false,
            interrupted: false,
            ok: nil,
            fail: nil,
            indeterminate: nil
        )
        appModel.activity.add(.init(kind: .warning, title: "Plugin batch cancel requested"))
    }

    func requestPluginPause() {
        guard pluginRunning, !pluginPauseRequested else { return }
        pluginPauseRequested = true
        pluginRunStatus = "Pausing after current archive finishes…"
        persistPluginCheckpointUI(
            pluginID: selectedPluginID ?? "",
            inProgress: true,
            paused: false,
            interrupted: false,
            ok: nil,
            fail: nil,
            indeterminate: nil
        )
        appModel.activity.add(.init(kind: .warning, title: "Plugin batch pause requested"))
    }

    func resumePluginBatchFromCheckpoint() {
        guard let profile = appModel.selectedProfile else { return }
        guard let checkpoint = resumablePluginBatch else { return }
        guard !checkpoint.arcids.isEmpty else {
            clearPluginBatchCheckpoint()
            refreshResumablePluginBatch()
            return
        }

        // Capture the editable delay before restoring the remaining checkpoint
        // settings. The updated checkpoint then becomes the source of truth for
        // this run and for any later pause/relaunch.
        let resumePlan = PluginBatchResumePlan(
            checkpoint: checkpoint,
            editedDelayText: pluginDelayText
        )
        let resumeCheckpoint = resumePlan.checkpoint
        savePluginBatchCheckpoint(resumeCheckpoint)
        resumablePluginBatch = resumeCheckpoint

        // Make the UI reflect the resumable batch context.
        appModel.selection.clear()
        appModel.selection.add(resumeCheckpoint.arcids)

        selectedPluginID = resumeCheckpoint.selectedPluginID
        pluginArgText = resumeCheckpoint.pluginArgText
        pluginDelayText = resumeCheckpoint.pluginDelayText
        if let mode = PluginApplyMode(rawValue: resumeCheckpoint.pluginApplyModeRaw) {
            pluginApplyMode = mode
        }
        restorePluginUIFromCheckpointIfNeeded(resumeCheckpoint)

        let startIndex = min(max(0, resumeCheckpoint.nextIndex), resumeCheckpoint.arcids.count)
        startPluginBatch(
            profile: profile,
            pluginID: resumeCheckpoint.selectedPluginID,
            pluginArgument: resumeCheckpoint.pluginArgText,
            delayText: resumeCheckpoint.pluginDelayText,
            arcids: resumeCheckpoint.arcids,
            startIndex: startIndex,
            resumed: true,
            initialOK: resumeCheckpoint.okCount ?? 0,
            initialFail: resumeCheckpoint.failCount ?? 0,
            initialIndeterminate: resumeCheckpoint.indeterminateCount ?? 0
        )
    }

    func refreshResumablePluginBatch() {
        guard let profile = appModel.selectedProfile else {
            resumablePluginBatch = nil
            pluginPaused = false
            return
        }
        guard let checkpoint = loadPluginBatchCheckpoint() else {
            resumablePluginBatch = nil
            pluginPaused = false
            return
        }
        if checkpoint.profileID == profile.id || checkpoint.profileBaseURL == profile.baseURL.absoluteString {
            resumablePluginBatch = checkpoint
            pluginPaused = checkpoint.paused ?? false
            restorePluginUIFromCheckpointIfNeeded(checkpoint)
        } else {
            resumablePluginBatch = nil
            pluginPaused = false
        }
    }
    func persistPluginCheckpointIndexAndUI(
        pluginID: String,
        nextIndex: Int,
        ok: Int,
        fail: Int,
        indeterminate: Int,
        total: Int
    ) {
        guard let existing = loadPluginBatchCheckpoint() else { return }
        var updated = existing
        updated.nextIndex = nextIndex
        updated.inProgress = true
        updated.paused = false
        updated.interrupted = false
        updated.okCount = ok
        updated.failCount = fail
        updated.indeterminateCount = indeterminate
        updated.lastRunStatus = pluginRunStatus
        updated.lastCurrentArchive = pluginCurrentArchive
        updated.lastLiveEvents = trimmedCheckpointEvents(pluginLiveEvents)
        updated.lastUpdatedAt = Date()
        savePluginBatchCheckpoint(updated)
    }

    func persistPluginCheckpointUI(
        pluginID: String,
        inProgress: Bool,
        paused: Bool,
        interrupted: Bool,
        ok: Int?,
        fail: Int?,
        indeterminate: Int?
    ) {
        guard let existing = loadPluginBatchCheckpoint() else { return }
        var updated = existing
        updated.inProgress = inProgress
        updated.paused = paused
        updated.interrupted = interrupted
        if let ok { updated.okCount = ok }
        if let fail { updated.failCount = fail }
        if let indeterminate { updated.indeterminateCount = indeterminate }
        updated.lastRunStatus = pluginRunStatus
        updated.lastCurrentArchive = pluginCurrentArchive
        updated.lastLiveEvents = trimmedCheckpointEvents(pluginLiveEvents)
        updated.lastUpdatedAt = Date()
        savePluginBatchCheckpoint(updated)
    }
    func restorePluginUIFromCheckpointIfNeeded(_ checkpoint: PluginBatchCheckpoint) {
        guard !running && !pluginRunning else { return }
        guard !restoredPluginCheckpointUI else { return }

        if (checkpoint.inProgress ?? false) && !(checkpoint.paused ?? false) {
            if var updated = loadPluginBatchCheckpoint() {
                updated.interrupted = true
                updated.lastRunStatus = updated.lastRunStatus ?? "Interrupted. Resume to continue."
                updated.lastUpdatedAt = Date()
                savePluginBatchCheckpoint(updated)
                resumablePluginBatch = updated
            }
        }

        pluginRunStatus = checkpoint.lastRunStatus ?? pluginRunStatus
        pluginCurrentArchive = checkpoint.lastCurrentArchive ?? pluginCurrentArchive
        pluginLiveEvents = checkpoint.lastLiveEvents ?? pluginLiveEvents
        pluginDelayText = checkpoint.pluginDelayText
        liveEvents = (checkpoint.lastLiveEvents ?? []).map { event in
            guard event.hasPrefix("["), let timestampEnd = event.firstIndex(of: "]") else {
                return "[PLUGIN] \(event)"
            }
            let message = event[event.index(after: timestampEnd)...].drop(while: { $0.isWhitespace })
            return "\(event[...timestampEnd]) [PLUGIN] \(message)"
        } + liveEvents
        restoredPluginCheckpointUI = true
    }
    func pluginCheckpointBannerText(_ checkpoint: PluginBatchCheckpoint) -> String {
        let state: String = {
            if checkpoint.interrupted ?? false { return "Interrupted" }
            if checkpoint.paused ?? false { return "Paused" }
            if checkpoint.inProgress ?? false { return "In progress" }
            return "Recoverable"
        }()
        return "\(state) plugin batch found (\(checkpoint.arcids.count) archives)."
    }
    func loadPluginBatchCheckpoint() -> PluginBatchCheckpoint? {
        guard let data = UserDefaults.standard.data(forKey: pluginBatchCheckpointKey) else { return nil }
        return try? JSONDecoder().decode(PluginBatchCheckpoint.self, from: data)
    }

    func savePluginBatchCheckpoint(_ checkpoint: PluginBatchCheckpoint) {
        if let data = try? JSONEncoder().encode(checkpoint) {
            UserDefaults.standard.set(data, forKey: pluginBatchCheckpointKey)
        }
    }

    func clearPluginBatchCheckpoint() {
        UserDefaults.standard.removeObject(forKey: pluginBatchCheckpointKey)
    }
    func refreshMetadataAfterPluginBatch(
        profile: Profile,
        arcid: String,
        previousSignature: String?
    ) async -> Bool {
        do {
            for attempt in 0..<6 {
                let latest = try await appModel.archives.metadata(profile: profile, arcid: arcid, forceRefresh: true)
                let latestSignature = PluginMetadataSupport.signature(title: latest.title ?? "", tags: latest.tags ?? "", summary: latest.summary ?? "")
                if previousSignature == nil || previousSignature != latestSignature {
                    return true
                }
                if attempt < 5 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            return false
        } catch {
            return false
        }
    }

    func mergeTagCSV(base: String, additions: String) -> String {
        var items = parseTags(base)
        var seen = Set(items.map { $0.lowercased() })
        for tag in parseTags(additions) {
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                items.append(tag)
            }
        }
        return items.joined(separator: ", ")
    }
    func pauseBetweenPluginRuns(
        seconds: Double,
        done: Int,
        total: Int,
        ok: Int,
        fail: Int,
        indeterminate: Int
    ) async -> Bool {
        guard seconds > 0 else { return false }
        let sliceNanos: UInt64 = 200_000_000
        let totalNanos = UInt64((seconds * 1_000_000_000).rounded())
        var elapsedNanos: UInt64 = 0

        while elapsedNanos < totalNanos {
            let shouldStop = await MainActor.run { pluginCancelRequested }
            if shouldStop || Task.isCancelled {
                return true
            }

            let remaining = totalNanos - elapsedNanos
            let step = min(sliceNanos, remaining)
            try? await Task.sleep(nanoseconds: step)
            elapsedNanos += step

            let elapsedSeconds = Double(elapsedNanos) / 1_000_000_000
            let remainingSeconds = max(0, seconds - elapsedSeconds)
            await MainActor.run {
                pluginRunStatus = "Processed \(done)/\(total) • Success \(ok) • Failed \(fail) • Indeterminate \(indeterminate) • Waiting \(delayDisplay(remainingSeconds))s…"
            }
        }

        return await MainActor.run { pluginCancelRequested }
    }

    func applyPluginPatch(
        _ patch: PluginMetadataPatch,
        currentTitle: String,
        currentTags: String,
        currentSummary: String,
        mode: PluginApplyMode
    ) -> (title: String, tags: String, summary: String) {
        let title = patch.title ?? currentTitle
        let summary = patch.summary ?? currentSummary

        let tags: String
        if let patchTags = patch.tags {
            switch mode {
            case .mergeWithExisting:
                tags = uniqueTagCSV(mergeTagCSV(base: currentTags, additions: patchTags))
            case .replaceWithPluginData:
                tags = uniqueTagCSV(patchTags)
            }
        } else {
            tags = uniqueTagCSV(currentTags)
        }

        return (title, tags, summary)
    }
}
