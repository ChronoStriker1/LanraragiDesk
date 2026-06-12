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

        if previewBeforeQueue {
            pluginRunStatus = "Generating preview for \(arcids.count) archives…"
            appendPluginLiveEvent("Preview started for \(pluginID) on \(arcids.count) archives")
            generatePreview(executePlugin: true)
            appModel.activity.add(.init(kind: .action, title: "Plugin batch preview generated", detail: "\(pluginID) on sample of \(arcids.count) selected"))
            return
        }

        let checkpoint = PluginBatchCheckpoint(
            profileID: profile.id,
            profileBaseURL: profile.baseURL.absoluteString,
            arcids: arcids,
            nextIndex: 0,
            selectedPluginID: pluginID,
            pluginArgText: pluginArgText,
            pluginDelayText: pluginDelayText,
            pluginApplyModeRaw: pluginApplyMode.rawValue,
            inProgress: true,
            paused: false,
            interrupted: false,
            okCount: 0,
            failCount: 0,
            lastRunStatus: "Running plugin on \(arcids.count) archives…",
            lastCurrentArchive: nil,
            lastLiveEvents: [],
            lastUpdatedAt: Date()
        )
        savePluginBatchCheckpoint(checkpoint)
        refreshResumablePluginBatch()

        startPluginBatch(
            profile: profile,
            pluginID: pluginID,
            arcids: arcids,
            startIndex: 0,
            resumed: false
        )
    }

    func startPluginBatch(
        profile: Profile,
        pluginID: String,
        arcids: [String],
        startIndex: Int,
        resumed: Bool
    ) {
        let delaySeconds = sanitizedDelaySeconds(from: pluginDelayText)

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
            pluginRunStatus = "Resumed \(pluginID) at archive \(startHuman)/\(arcids.count)…"
            appendPluginLiveEvent("Resumed \(pluginID) at \(startHuman)/\(arcids.count)")
            appModel.activity.add(.init(kind: .action, title: "Plugin batch resumed", detail: "\(pluginID) at \(startHuman)/\(arcids.count)"))
        } else {
            pluginRunStatus = "Running plugin on \(arcids.count) archives…"
            appModel.activity.add(.init(kind: .action, title: "Plugin batch queued", detail: "\(pluginID) on \(arcids.count) archives"))
            appendPluginLiveEvent("Started \(pluginID) on \(arcids.count) archives")
        }

        pluginTask?.cancel()
        pluginTask = Task {
            var ok = 0
            var fail = 0
            for index in startIndex..<arcids.count {
                let arcid = arcids[index]
                if await MainActor.run(body: { pluginCancelRequested || pluginPauseRequested }) { break }
                await MainActor.run {
                    pluginCurrentArchive = displayName(for: arcid)
                    appendPluginLiveEvent("Processing \(displayName(for: arcid))")
                }

                persistPluginCheckpointIndexAndUI(pluginID: pluginID, nextIndex: index, ok: ok, fail: fail, total: arcids.count)

                do {
                    let prePluginMeta = try? await appModel.archives.metadata(profile: profile, arcid: arcid, forceRefresh: true)
                    let preSignature = prePluginMeta.map {
                        metadataSignature(title: $0.title ?? "", tags: $0.tags ?? "", summary: $0.summary ?? "")
                    }

                    let job = try await pluginsVM.queue(profile: profile, pluginID: pluginID, arcid: arcid, arg: pluginArgText)
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
                        if state == .failed {
                            fail += 1
                            appModel.activity.add(.init(kind: .warning, title: "Plugin job failed", detail: "\(pluginID) • \(arcid) • job \(job.job)"))
                            await MainActor.run {
                                appendPluginLiveEvent("Job \(job.job) failed for \(displayName(for: arcid))")
                            }
                        } else {
                            let changed = await refreshMetadataAfterPluginBatch(profile: profile, arcid: arcid, previousSignature: preSignature)
                            if !changed {
                                _ = await applyMetadataFromPluginOutputBatch(
                                    profile: profile,
                                    pluginID: pluginID,
                                    arcid: arcid,
                                    previousSignature: preSignature,
                                    applyMode: pluginApplyMode
                                )
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
                    } else {
                        let changed = await refreshMetadataAfterPluginBatch(profile: profile, arcid: arcid, previousSignature: preSignature)
                        if !changed {
                            _ = await applyMetadataFromPluginOutputBatch(
                                profile: profile,
                                pluginID: pluginID,
                                arcid: arcid,
                                previousSignature: preSignature,
                                applyMode: pluginApplyMode
                            )
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
                    pluginRunStatus = "Processed \(index + 1)/\(arcids.count) • Success \(ok) • Failed \(fail)…"
                }
                persistPluginCheckpointIndexAndUI(pluginID: pluginID, nextIndex: index, ok: ok, fail: fail, total: arcids.count)

                if await MainActor.run(body: { pluginPauseRequested }) {
                    if let existing = loadPluginBatchCheckpoint() {
                        var updated = existing
                        // Redo the last touched archive on resume.
                        updated.nextIndex = max(0, index)
                        updated.paused = true
                        updated.inProgress = true
                        updated.interrupted = false
                        updated.okCount = ok
                        updated.failCount = fail
                        updated.lastRunStatus = pluginRunStatus
                        updated.lastCurrentArchive = pluginCurrentArchive
                        updated.lastLiveEvents = trimmedCheckpointEvents(pluginLiveEvents)
                        updated.lastUpdatedAt = Date()
                        savePluginBatchCheckpoint(updated)
                    }
                    break
                }

                if index + 1 < arcids.count && delaySeconds > 0 {
                    if await pauseBetweenPluginRuns(seconds: delaySeconds, done: index + 1, total: arcids.count, ok: ok, fail: fail) {
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
                    pluginRunStatus = "Paused. Success \(ok), failed \(fail)."
                    pluginPaused = true
                } else if cancelledByRequest {
                    pluginRunStatus = "Cancelled. Success \(ok), failed \(fail)."
                } else {
                    pluginRunStatus = "Done. Success \(ok), failed \(fail)."
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
                    fail: fail
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
                    fail: fail
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
                    fail: fail
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
            fail: nil
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
            fail: nil
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

        // Make the UI reflect the resumable batch context.
        appModel.selection.clear()
        appModel.selection.add(checkpoint.arcids)

        selectedPluginID = checkpoint.selectedPluginID
        pluginArgText = checkpoint.pluginArgText
        pluginDelayText = checkpoint.pluginDelayText
        if let mode = PluginApplyMode(rawValue: checkpoint.pluginApplyModeRaw) {
            pluginApplyMode = mode
        }
        restorePluginUIFromCheckpointIfNeeded(checkpoint)

        let startIndex = min(max(0, checkpoint.nextIndex), max(0, checkpoint.arcids.count - 1))
        startPluginBatch(
            profile: profile,
            pluginID: checkpoint.selectedPluginID,
            arcids: checkpoint.arcids,
            startIndex: startIndex,
            resumed: true
        )
    }

    func refreshResumablePluginBatch() {
        guard let profile = appModel.selectedProfile else {
            resumablePluginBatch = nil
            return
        }
        guard let checkpoint = loadPluginBatchCheckpoint() else {
            resumablePluginBatch = nil
            return
        }
        if checkpoint.profileID == profile.id || checkpoint.profileBaseURL == profile.baseURL.absoluteString {
            resumablePluginBatch = checkpoint
            restorePluginUIFromCheckpointIfNeeded(checkpoint)
        } else {
            resumablePluginBatch = nil
        }
    }
    func persistPluginCheckpointIndexAndUI(pluginID: String, nextIndex: Int, ok: Int, fail: Int, total: Int) {
        guard let existing = loadPluginBatchCheckpoint() else { return }
        var updated = existing
        updated.nextIndex = nextIndex
        updated.inProgress = true
        updated.paused = false
        updated.interrupted = false
        updated.okCount = ok
        updated.failCount = fail
        updated.lastRunStatus = pluginRunStatus
        updated.lastCurrentArchive = pluginCurrentArchive
        updated.lastLiveEvents = trimmedCheckpointEvents(pluginLiveEvents)
        updated.lastUpdatedAt = Date()
        savePluginBatchCheckpoint(updated)
    }

    func persistPluginCheckpointUI(pluginID: String, inProgress: Bool, paused: Bool, interrupted: Bool, ok: Int?, fail: Int?) {
        guard let existing = loadPluginBatchCheckpoint() else { return }
        var updated = existing
        updated.inProgress = inProgress
        updated.paused = paused
        updated.interrupted = interrupted
        if let ok { updated.okCount = ok }
        if let fail { updated.failCount = fail }
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
        liveEvents = (checkpoint.lastLiveEvents ?? []).map { "[PLUGIN] \($0)" } + liveEvents
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
                let latestSignature = metadataSignature(title: latest.title ?? "", tags: latest.tags ?? "", summary: latest.summary ?? "")
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

    func applyMetadataFromPluginOutputBatch(
        profile: Profile,
        pluginID: String,
        arcid: String,
        previousSignature: String?,
        applyMode: PluginApplyMode
    ) async -> Bool {
        do {
            let raw = try await pluginsVM.run(profile: profile, pluginID: pluginID, arcid: arcid, arg: pluginArgText)
            guard let patch = parsePluginMetadataPatch(from: raw) else {
                // Some plugins apply metadata directly during /use and return no structured patch payload.
                let changed = await refreshMetadataAfterPluginBatch(
                    profile: profile,
                    arcid: arcid,
                    previousSignature: previousSignature
                )
                if changed {
                    appModel.activity.add(.init(kind: .action, title: "Plugin metadata refreshed", detail: "\(pluginID) • \(arcid)"))
                }
                return changed
            }

            let current = try await appModel.archives.metadata(profile: profile, arcid: arcid, forceRefresh: true)
            let currentTitle = (current.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let currentSummary = (current.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let currentTagsRaw = current.tags ?? ""

            let applied = applyPluginPatch(
                patch,
                currentTitle: currentTitle,
                currentTags: currentTagsRaw,
                currentSummary: currentSummary,
                mode: applyMode
            )
            let titleToSave = applied.title
            let summaryToSave = applied.summary
            let tagsToSave = applied.tags

            let beforeSignature = previousSignature ?? metadataSignature(title: currentTitle, tags: currentTagsRaw, summary: currentSummary)
            let nextSignature = metadataSignature(title: titleToSave, tags: tagsToSave, summary: summaryToSave)
            guard beforeSignature != nextSignature else { return false }

            _ = try await appModel.archives.updateMetadata(
                profile: profile,
                arcid: arcid,
                title: titleToSave,
                tags: tagsToSave,
                summary: summaryToSave
            )
            appModel.activity.add(.init(kind: .action, title: "Plugin output applied", detail: "\(pluginID) • \(arcid)"))
            return true
        } catch {
            appModel.activity.add(.init(kind: .warning, title: "Plugin output apply failed", detail: "\(pluginID) • \(arcid)\n\(error)"))
            return false
        }
    }

    func parsePluginMetadataPatch(from response: String) -> (title: String?, tags: String?, summary: String?)? {
        guard
            let data = response.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }

        func scalarString(_ value: Any?) -> String? {
            guard let value else { return nil }
            if let str = value as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let num = value as? NSNumber {
                if CFGetTypeID(num) == CFBooleanGetTypeID() {
                    return num.boolValue ? "true" : "false"
                }
                return num.stringValue
            }
            return nil
        }

        func csvString(_ value: Any?) -> String? {
            if let scalar = scalarString(value) {
                return scalar
            }
            if let arr = value as? [Any] {
                let parts = arr.compactMap { scalarString($0) }
                guard !parts.isEmpty else { return nil }
                return parts.joined(separator: ", ")
            }
            return nil
        }

        func parseJSONDictionaryString(_ value: String) -> [String: Any]? {
            guard let rawData = value.data(using: .utf8),
                  let nested = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
                return nil
            }
            return nested
        }

        func extractPayload(_ value: Any) -> [String: Any]? {
            if let dict = value as? [String: Any] {
                if let nested = dict["data"] {
                    if let payload = extractPayload(nested) {
                        return payload
                    }
                }
                for key in ["result", "metadata", "plugin_data", "plugin_result"] {
                    if let nested = dict[key], let payload = extractPayload(nested) {
                        return payload
                    }
                }
                if dict["title"] != nil || dict["summary"] != nil || dict["new_tags"] != nil || dict["tags"] != nil {
                    return dict
                }
            }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let nested = parseJSONDictionaryString(trimmed) {
                    return extractPayload(nested)
                }
            }
            return nil
        }

        guard let payload = extractPayload(obj) else { return nil }

        let title = scalarString(payload["title"])
        let summary = scalarString(payload["summary"])
        let newTags = csvString(payload["new_tags"])
        let fullTags = csvString(payload["tags"])

        let tags = [newTags, fullTags]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedTitle = (title?.isEmpty == true) ? nil : title
        let normalizedSummary = (summary?.isEmpty == true) ? nil : summary
        let normalizedTags = tags.isEmpty ? nil : tags

        guard normalizedTitle != nil || normalizedSummary != nil || normalizedTags != nil else {
            return nil
        }
        return (normalizedTitle, normalizedTags, normalizedSummary)
    }

    func metadataSignature(title: String, tags: String, summary: String) -> String {
        [
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizeTags(tags),
            summary.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "|||")
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
        fail: Int
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
                pluginRunStatus = "Processed \(done)/\(total) • Success \(ok) • Failed \(fail) • Waiting \(delayDisplay(remainingSeconds))s…"
            }
        }

        return await MainActor.run { pluginCancelRequested }
    }

    func applyPluginPatch(
        _ patch: (title: String?, tags: String?, summary: String?),
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
