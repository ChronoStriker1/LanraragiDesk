import Foundation
import SwiftUI
import LanraragiKit

// MARK: - Tag batch run engine

extension BatchView {
    func run() {
        guard let profile = appModel.selectedProfile else { return }
        let add = parseTags(addTagsText)
        let remove = parseTags(removeTagsText)
        let arcids = Array(appModel.selection.arcids).sorted()
        if arcids.isEmpty { return }
        if add.isEmpty && remove.isEmpty { return }

        let checkpoint = TagBatchCheckpoint(
            profileID: profile.id,
            profileBaseURL: profile.baseURL.absoluteString,
            arcids: arcids,
            nextIndex: 0,
            addTagsText: addTagsText,
            removeTagsText: removeTagsText,
            inProgress: true,
            paused: false,
            interrupted: false,
            doneCount: 0,
            errorCount: 0,
            lastProgressText: "Starting…",
            lastCurrentArchive: nil,
            lastErrors: [],
            lastLiveEvents: [],
            lastUpdatedAt: Date()
        )
        saveTagBatchCheckpoint(checkpoint)
        refreshResumableTagBatch()

        startTagBatch(
            profile: profile,
            arcids: arcids,
            add: add,
            remove: remove,
            startIndex: 0,
            resumed: false
        )
    }

    func startTagBatch(
        profile: Profile,
        arcids: [String],
        add: [String],
        remove: [String],
        startIndex: Int,
        resumed: Bool
    ) {
        running = true
        batchCancelRequested = false
        batchPauseRequested = false
        batchPaused = false
        batchCurrentArchive = nil
        errors = []
        if !resumed {
            batchLiveEvents = []
        }
        if resumed {
            let startHuman = min(max(startIndex + 1, 1), max(arcids.count, 1))
            progressText = "Resumed at archive \(startHuman)/\(arcids.count)…"
            appendBatchLiveEvent("Resumed at \(startHuman)/\(arcids.count)")
            appModel.activity.add(.init(kind: .action, title: "Tag batch resumed", detail: "\(startHuman)/\(arcids.count)"))
        } else {
            progressText = "Starting…"
            appModel.activity.add(.init(kind: .action, title: "Batch started", detail: "\(arcids.count) archives"))
            appendBatchLiveEvent("Started \(arcids.count) archives")
        }
        persistTagCheckpointUI(
            inProgress: true,
            paused: false,
            interrupted: false,
            doneCount: 0,
            errorCount: 0,
            progressText: progressText,
            currentArchive: nil
        )

        task?.cancel()
        task = Task {
            var done = 0
            for index in startIndex..<arcids.count {
                let arcid = arcids[index]
                if await MainActor.run(body: { batchCancelRequested || batchPauseRequested }) { break }
                await MainActor.run {
                    batchCurrentArchive = displayName(for: arcid)
                }

                persistTagCheckpointIndexAndUI(nextIndex: index, done: done, total: arcids.count)

                do {
                    let meta = try await appModel.archives.metadata(profile: profile, arcid: arcid)
                    if await MainActor.run(body: { batchCancelRequested }) { break }
                    let oldTags = meta.tags ?? ""
                    let newTags = applyTagEdits(old: oldTags, add: add, remove: remove)
                    if normalizeTags(oldTags) == normalizeTags(newTags) {
                        await MainActor.run {
                            appendBatchLiveEvent("No changes for \(displayName(for: arcid))")
                        }
                        done += 1
                        await MainActor.run {
                            progressText = "Processed \(done)/\(arcids.count)…"
                        }
                        persistTagCheckpointIndexAndUI(nextIndex: index, done: done, total: arcids.count)
                        continue
                    }

                    _ = try await appModel.archives.updateMetadata(
                        profile: profile,
                        arcid: arcid,
                        title: meta.title ?? "",
                        tags: newTags,
                        summary: meta.summary ?? ""
                    )
                    await MainActor.run {
                        appendBatchLiveEvent(metadataChangeLiveMessage(
                            prefix: "Saved",
                            arcid: arcid,
                            beforeTitle: meta.title ?? "",
                            beforeTags: oldTags,
                            beforeSummary: meta.summary ?? "",
                            afterTitle: meta.title ?? "",
                            afterTags: newTags,
                            afterSummary: meta.summary ?? ""
                        ))
                    }
                } catch {
                    let msg = "\(arcid): \(ErrorPresenter.short(error))"
                    await MainActor.run {
                        errors.append(msg)
                        appendBatchLiveEvent("Failed \(displayName(for: arcid)): \(ErrorPresenter.short(error))")
                    }
                }

                done += 1
                await MainActor.run {
                    progressText = "Processed \(index + 1)/\(arcids.count)…"
                }
                persistTagCheckpointIndexAndUI(nextIndex: index, done: done, total: arcids.count)

                if await MainActor.run(body: { batchPauseRequested }) {
                    if let existing = loadTagBatchCheckpoint() {
                        var updated = existing
                        // Redo the last touched archive on resume.
                        updated.nextIndex = max(0, index)
                        updated.paused = true
                        updated.inProgress = true
                        updated.interrupted = false
                        updated.lastProgressText = progressText
                        updated.lastCurrentArchive = batchCurrentArchive
                        updated.doneCount = done
                        updated.errorCount = errors.count
                        updated.lastErrors = Array(errors.prefix(50))
                        updated.lastLiveEvents = trimmedCheckpointEvents(batchLiveEvents)
                        updated.lastUpdatedAt = Date()
                        saveTagBatchCheckpoint(updated)
                    }
                    break
                }
            }

            let cancelledByRequest = await MainActor.run { batchCancelRequested }
            let pausedByRequest = await MainActor.run { batchPauseRequested }
            let wasCancelled = cancelledByRequest || Task.isCancelled

            await MainActor.run {
                running = false
                batchCurrentArchive = nil
                if pausedByRequest {
                    progressText = "Paused. Processed \(done)/\(arcids.count) with \(errors.count) errors."
                    batchPaused = true
                } else if wasCancelled {
                    progressText = "Cancelled."
                } else if errors.isEmpty {
                    progressText = "Done."
                } else {
                    progressText = "Done with \(errors.count) errors."
                }
                batchCancelRequested = false
                batchPauseRequested = false
                task = nil
            }

            if pausedByRequest {
                appModel.activity.add(.init(kind: .warning, title: "Batch paused"))
                persistTagCheckpointUI(
                    inProgress: true,
                    paused: true,
                    interrupted: false,
                    doneCount: done,
                    errorCount: errors.count,
                    progressText: progressText,
                    currentArchive: nil
                )
                await MainActor.run {
                    refreshResumableTagBatch()
                }
            } else if wasCancelled {
                persistTagCheckpointUI(
                    inProgress: false,
                    paused: false,
                    interrupted: false,
                    doneCount: done,
                    errorCount: errors.count,
                    progressText: progressText,
                    currentArchive: nil
                )
                clearTagBatchCheckpoint()
                await MainActor.run {
                    refreshResumableTagBatch()
                }
                appModel.activity.add(.init(kind: .warning, title: "Batch cancelled"))
            } else if errors.isEmpty {
                persistTagCheckpointUI(
                    inProgress: false,
                    paused: false,
                    interrupted: false,
                    doneCount: done,
                    errorCount: 0,
                    progressText: progressText,
                    currentArchive: nil
                )
                clearTagBatchCheckpoint()
                await MainActor.run {
                    refreshResumableTagBatch()
                }
                appModel.activity.add(.init(kind: .action, title: "Batch completed", detail: "\(arcids.count) archives"))
            } else {
                persistTagCheckpointUI(
                    inProgress: false,
                    paused: false,
                    interrupted: false,
                    doneCount: done,
                    errorCount: errors.count,
                    progressText: progressText,
                    currentArchive: nil
                )
                clearTagBatchCheckpoint()
                await MainActor.run {
                    refreshResumableTagBatch()
                }
                appModel.activity.add(.init(kind: .warning, title: "Batch completed with errors", detail: "\(errors.count) errors"))
            }
        }
    }

    func requestBatchCancel() {
        guard running, !batchCancelRequested else { return }
        batchCancelRequested = true
        progressText = "Stopping after current archive save finishes…"
        persistTagCheckpointUI(
            inProgress: true,
            paused: false,
            interrupted: false,
            doneCount: nil,
            errorCount: nil,
            progressText: progressText,
            currentArchive: batchCurrentArchive
        )
        appModel.activity.add(.init(kind: .warning, title: "Batch cancel requested"))
    }

    func requestBatchPause() {
        guard running, !batchPauseRequested else { return }
        batchPauseRequested = true
        progressText = "Pausing after current archive save finishes…"
        persistTagCheckpointUI(
            inProgress: true,
            paused: false,
            interrupted: false,
            doneCount: nil,
            errorCount: nil,
            progressText: progressText,
            currentArchive: batchCurrentArchive
        )
        appModel.activity.add(.init(kind: .warning, title: "Batch pause requested"))
    }

    func resumeTagBatchFromCheckpoint() {
        guard let profile = appModel.selectedProfile else { return }
        guard let checkpoint = resumableTagBatch else { return }
        guard !checkpoint.arcids.isEmpty else {
            clearTagBatchCheckpoint()
            refreshResumableTagBatch()
            return
        }

        // Make the UI reflect the resumable batch context.
        appModel.selection.clear()
        appModel.selection.add(checkpoint.arcids)

        addTagsText = checkpoint.addTagsText
        removeTagsText = checkpoint.removeTagsText
        restoreTagUIFromCheckpointIfNeeded(checkpoint)

        let add = parseTags(checkpoint.addTagsText)
        let remove = parseTags(checkpoint.removeTagsText)
        if add.isEmpty && remove.isEmpty {
            clearTagBatchCheckpoint()
            refreshResumableTagBatch()
            return
        }

        let startIndex = min(max(0, checkpoint.nextIndex), max(0, checkpoint.arcids.count - 1))
        startTagBatch(
            profile: profile,
            arcids: checkpoint.arcids,
            add: add,
            remove: remove,
            startIndex: startIndex,
            resumed: true
        )
    }

    func refreshResumableTagBatch() {
        guard let profile = appModel.selectedProfile else {
            resumableTagBatch = nil
            return
        }
        guard let checkpoint = loadTagBatchCheckpoint() else {
            resumableTagBatch = nil
            return
        }
        if checkpoint.profileID == profile.id || checkpoint.profileBaseURL == profile.baseURL.absoluteString {
            resumableTagBatch = checkpoint
            restoreTagUIFromCheckpointIfNeeded(checkpoint)
        } else {
            resumableTagBatch = nil
        }
    }

    func loadTagBatchCheckpoint() -> TagBatchCheckpoint? {
        guard let data = UserDefaults.standard.data(forKey: tagBatchCheckpointKey) else { return nil }
        return try? JSONDecoder().decode(TagBatchCheckpoint.self, from: data)
    }

    func saveTagBatchCheckpoint(_ checkpoint: TagBatchCheckpoint) {
        if let data = try? JSONEncoder().encode(checkpoint) {
            UserDefaults.standard.set(data, forKey: tagBatchCheckpointKey)
        }
    }

    func clearTagBatchCheckpoint() {
        UserDefaults.standard.removeObject(forKey: tagBatchCheckpointKey)
    }

    func parseTags(_ s: String) -> [String] {
        TagParsing.tokens(s)
    }

    func normalizeTags(_ s: String) -> String {
        parseTags(s).map { $0.lowercased() }.sorted().joined(separator: ",")
    }

    func applyTagEdits(old: String, add: [String], remove: [String]) -> String {
        var items = parseTags(old)
        var setLower = Set(items.map { $0.lowercased() })

        let removeLower = Set(remove.map { $0.lowercased() })
        if !removeLower.isEmpty {
            items.removeAll { removeLower.contains($0.lowercased()) }
            setLower = Set(items.map { $0.lowercased() })
        }

        for a in add {
            let key = a.lowercased()
            if setLower.insert(key).inserted {
                items.append(a)
            }
        }

        return items.joined(separator: ", ")
    }
    func trimmedCheckpointEvents(_ events: [String]) -> [String] {
        Array(events.prefix(200))
    }
    func persistTagCheckpointIndexAndUI(nextIndex: Int, done: Int, total: Int) {
        guard let existing = loadTagBatchCheckpoint() else { return }
        var updated = existing
        updated.nextIndex = nextIndex
        updated.inProgress = true
        updated.paused = false
        updated.interrupted = false
        updated.doneCount = done
        updated.errorCount = errors.count
        updated.lastProgressText = progressText
        updated.lastCurrentArchive = batchCurrentArchive
        updated.lastErrors = Array(errors.prefix(50))
        updated.lastLiveEvents = trimmedCheckpointEvents(batchLiveEvents)
        updated.lastUpdatedAt = Date()
        saveTagBatchCheckpoint(updated)
    }

    func persistTagCheckpointUI(
        inProgress: Bool,
        paused: Bool,
        interrupted: Bool,
        doneCount: Int?,
        errorCount: Int?,
        progressText: String?,
        currentArchive: String?
    ) {
        guard let existing = loadTagBatchCheckpoint() else { return }
        var updated = existing
        updated.inProgress = inProgress
        updated.paused = paused
        updated.interrupted = interrupted
        if let doneCount { updated.doneCount = doneCount }
        if let errorCount { updated.errorCount = errorCount }
        updated.lastProgressText = progressText
        updated.lastCurrentArchive = currentArchive
        updated.lastErrors = Array(errors.prefix(50))
        updated.lastLiveEvents = trimmedCheckpointEvents(batchLiveEvents)
        updated.lastUpdatedAt = Date()
        saveTagBatchCheckpoint(updated)
    }
    func restoreTagUIFromCheckpointIfNeeded(_ checkpoint: TagBatchCheckpoint) {
        guard !running && !pluginRunning else { return }
        guard !restoredTagCheckpointUI else { return }

        // If the app was closed mid-run, treat as interrupted and surface context.
        if (checkpoint.inProgress ?? false) && !(checkpoint.paused ?? false) {
            if var updated = loadTagBatchCheckpoint() {
                updated.interrupted = true
                updated.lastProgressText = updated.lastProgressText ?? "Interrupted. Resume to continue."
                updated.lastUpdatedAt = Date()
                saveTagBatchCheckpoint(updated)
                resumableTagBatch = updated
            }
        }

        progressText = checkpoint.lastProgressText ?? progressText
        batchCurrentArchive = checkpoint.lastCurrentArchive ?? batchCurrentArchive
        errors = checkpoint.lastErrors ?? errors
        batchLiveEvents = checkpoint.lastLiveEvents ?? batchLiveEvents
        // Ensure combined log reflects restored events.
        liveEvents = (checkpoint.lastLiveEvents ?? []).map { "[TAG] \($0)" } + liveEvents
        restoredTagCheckpointUI = true
    }
    func tagCheckpointBannerText(_ checkpoint: TagBatchCheckpoint) -> String {
        let state: String = {
            if checkpoint.interrupted ?? false { return "Interrupted" }
            if checkpoint.paused ?? false { return "Paused" }
            if checkpoint.inProgress ?? false { return "In progress" }
            return "Recoverable"
        }()
        return "\(state) tag batch found (\(checkpoint.arcids.count) archives)."
    }
}
