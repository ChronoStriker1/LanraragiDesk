import Foundation
import SwiftUI
import LanraragiKit

struct BatchView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var pluginsVM = PluginsViewModel()
    @StateObject private var runState = BatchRunState.shared

    @State private var addTagsText: String = ""
    @State private var removeTagsText: String = ""
    @State private var selectedPluginID: String?
    @State private var pluginArgText: String = ""
    @State private var pluginDelayText: String = "4"
    @State private var pluginApplyMode: PluginApplyMode = .mergeWithExisting
    @State private var showPluginSettings: Bool = false
    @State private var selectedArchiveNames: [String: String] = [:]
    @State private var selectedNamesTask: Task<Void, Never>?
    @State private var previewRows: [BatchPreviewRow] = []
    @State private var previewStatus: String?
    @State private var previewRunning: Bool = false
    @State private var previewTask: Task<Void, Never>?
    @State private var previewBeforeQueue: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Batch")
                    .font(.title2)
                    .bold()
                Spacer()
                Text("\(appModel.selection.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Clear Selection") { appModel.selection.clear() }
                    .disabled(appModel.selection.count == 0 || running || pluginRunning)
            }

            GroupBox("Selected archives") {
                VStack(alignment: .leading, spacing: 8) {
                    if selectedArcidsSorted.isEmpty {
                        Text("No archives selected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(selectedArcidsSorted, id: \.self) { arcid in
                                    HStack(spacing: 8) {
                                        Button {
                                            appModel.selection.remove(arcid)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(running || pluginRunning)

                                        Text(displayName(for: arcid))
                                            .font(.caption)
                                            .lineLimit(1)
                                            .textSelection(.enabled)
                                            .help(arcid)
                                        Spacer()
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                }
                .padding(8)
            }
            .debugFrameNumber(5)

            GroupBox("Preview (sample)") {
                VStack(alignment: .leading, spacing: 10) {
                    if !previewBeforeQueue {
                        Text("Preview is disabled. Enable \"Preview Before Queue\" in Plugin operations to run a sample preview.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let previewStatus {
                        Text(previewStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !previewRows.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(previewRows) { row in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.filename)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        Text(row.detail)
                                            .font(.caption2)
                                            .foregroundStyle(row.kind == .error ? .red : .secondary)
                                            .textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color.primary.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
                .padding(8)
            }
            .debugFrameNumber(6)

            GroupBox("Tag operations") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Add tags (comma separated)", text: $addTagsText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(running || pluginRunning)
                    TextField("Remove tags (comma separated)", text: $removeTagsText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(running || pluginRunning)

                    HStack {
                        Button(running ? "Running…" : "Run") {
                            run()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || pluginRunning || appModel.selection.count == 0 || (parseTags(addTagsText).isEmpty && parseTags(removeTagsText).isEmpty))

                        Button(batchCancelRequested ? "Stopping…" : "Cancel", role: .destructive) {
                            requestBatchCancel()
                        }
                        .disabled(!running || batchCancelRequested)

                        Spacer()
                    }

                    if let progressText {
                        Text(progressText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if running || !batchLiveEvents.isEmpty {
                        if let batchCurrentArchive {
                            Text("Current: \(batchCurrentArchive)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(batchLiveEvents, id: \.self) { event in
                                    Text(event)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }
                .padding(8)
            }
            .debugFrameNumber(2)

            GroupBox("Plugin operations") {
                VStack(alignment: .leading, spacing: 10) {
                    if let status = pluginsVM.statusText {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Picker("Plugin", selection: $selectedPluginID) {
                            Text("Select plugin").tag(Optional<String>.none)
                            ForEach(pluginsVM.plugins, id: \.id) { p in
                                Text(p.title).tag(Optional(p.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(pluginsVM.plugins.isEmpty || running || pluginRunning)

                        Button("Refresh Plugins") {
                            Task { await loadPlugins() }
                        }
                        .disabled(running || pluginRunning)
                    }

                    if let plugin = selectedPlugin {
                        if let d = plugin.description, !d.isEmpty {
                            Text(d)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if !plugin.parameters.isEmpty {
                            DisclosureGroup(isExpanded: $showPluginSettings) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(plugin.parameters) { param in
                                            pluginOptionRow(param)
                                        }
                                    }
                                }
                                .frame(minHeight: 66, maxHeight: 150)
                                .padding(.top, 4)
                            } label: {
                                Text("Plugin settings")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }

                    TextField(selectedPlugin?.oneshotArg ?? "Plugin URL/arg (optional)", text: $pluginArgText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(running || pluginRunning)

                    HStack {
                        Picker("Save mode", selection: $pluginApplyMode) {
                            ForEach(PluginApplyMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(running || pluginRunning || previewRunning)

                        Toggle("Preview Before Queue", isOn: $previewBeforeQueue)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .disabled(running || pluginRunning || previewRunning)

                        HStack(spacing: 8) {
                            Text("Delay (sec)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("4", text: $pluginDelayText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .disabled(running || pluginRunning)
                            Text("between runs")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Button(pluginRunning ? "Queueing…" : "Queue Plugin") {
                            runPluginBatch()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || pluginRunning || previewRunning || selectedPluginID == nil || appModel.selection.count == 0)

                        Button(pluginCancelRequested ? "Stopping…" : "Cancel", role: .destructive) {
                            requestPluginCancel()
                        }
                        .disabled(!pluginRunning || pluginCancelRequested)

                        Spacer()
                    }

                    if let pluginRunStatus {
                        Text(pluginRunStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if pluginRunning || !pluginLiveEvents.isEmpty {
                        if let pluginCurrentArchive {
                            Text("Current: \(pluginCurrentArchive)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(pluginLiveEvents, id: \.self) { event in
                                    Text(event)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 130)
                    }
                }
                .padding(8)
            }
            .debugFrameNumber(4)

            if !errors.isEmpty {
                GroupBox("Errors") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(errors, id: \.self) { e in
                                Text(e)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(maxHeight: 220)
                }
                .debugFrameNumber(3)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .debugFrameNumber(1)
        .onDisappear {
            selectedNamesTask?.cancel()
            previewTask?.cancel()
        }
        .task(id: appModel.selectedProfileID) {
            await loadPlugins()
            refreshSelectedArchiveNames()
        }
        .onChange(of: selectedArcidsSorted) { _, _ in
            refreshSelectedArchiveNames()
            invalidatePreview()
        }
        .onChange(of: addTagsText) { _, _ in invalidatePreview() }
        .onChange(of: removeTagsText) { _, _ in invalidatePreview() }
        .onChange(of: selectedPluginID) { _, _ in
            applyDefaultPluginDelayFromSelection()
            invalidatePreview()
        }
        .onChange(of: pluginArgText) { _, _ in invalidatePreview() }
        .onChange(of: pluginDelayText) { _, _ in invalidatePreview() }
        .onChange(of: previewBeforeQueue) { _, _ in
            if !previewBeforeQueue {
                invalidatePreview()
            }
        }
    }

    private func run() {
        guard let profile = appModel.selectedProfile else { return }
        let add = parseTags(addTagsText)
        let remove = parseTags(removeTagsText)
        let arcids = Array(appModel.selection.arcids).sorted()
        if arcids.isEmpty { return }

        running = true
        batchCancelRequested = false
        batchCurrentArchive = nil
        batchLiveEvents = []
        errors = []
        progressText = "Starting…"
        appModel.activity.add(.init(kind: .action, title: "Batch started", detail: "\(arcids.count) archives"))
        appendBatchLiveEvent("Started \(arcids.count) archives")

        task?.cancel()
        task = Task {
            var done = 0
            for arcid in arcids {
                if await MainActor.run(body: { batchCancelRequested }) { break }
                await MainActor.run {
                    batchCurrentArchive = displayName(for: arcid)
                }
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
                    progressText = "Processed \(done)/\(arcids.count)…"
                }
            }

            let cancelledByRequest = await MainActor.run { batchCancelRequested }
            let wasCancelled = cancelledByRequest || Task.isCancelled

            await MainActor.run {
                running = false
                batchCurrentArchive = nil
                if wasCancelled {
                    progressText = "Cancelled."
                } else if errors.isEmpty {
                    progressText = "Done."
                } else {
                    progressText = "Done with \(errors.count) errors."
                }
                batchCancelRequested = false
                task = nil
            }

            if wasCancelled {
                appModel.activity.add(.init(kind: .warning, title: "Batch cancelled"))
            } else if errors.isEmpty {
                appModel.activity.add(.init(kind: .action, title: "Batch completed", detail: "\(arcids.count) archives"))
            } else {
                appModel.activity.add(.init(kind: .warning, title: "Batch completed with errors", detail: "\(errors.count) errors"))
            }
        }
    }

    private func requestBatchCancel() {
        guard running, !batchCancelRequested else { return }
        batchCancelRequested = true
        progressText = "Stopping after current archive save finishes…"
        appModel.activity.add(.init(kind: .warning, title: "Batch cancel requested"))
    }

    private func parseTags(_ s: String) -> [String] {
        s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func normalizeTags(_ s: String) -> String {
        parseTags(s).map { $0.lowercased() }.sorted().joined(separator: ",")
    }

    private func applyTagEdits(old: String, add: [String], remove: [String]) -> String {
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

    private func loadPlugins() async {
        guard let profile = appModel.selectedProfile else { return }
        await pluginsVM.load(profile: profile)
        if let selectedPluginID, pluginsVM.plugins.contains(where: { $0.id == selectedPluginID }) {
            applyDefaultPluginDelayFromSelection()
            return
        }
        selectedPluginID = pluginsVM.plugins.first?.id
        applyDefaultPluginDelayFromSelection()
    }

    private func runPluginBatch() {
        guard let profile = appModel.selectedProfile else { return }
        guard let pluginID = selectedPluginID else { return }
        let arcids = selectedArcidsSorted
        guard !arcids.isEmpty else { return }

        if previewBeforeQueue {
            generatePreview(executePlugin: true)
            appModel.activity.add(.init(kind: .action, title: "Plugin batch preview generated", detail: "\(pluginID) on sample of \(arcids.count) selected"))
            return
        }

        let delaySeconds = sanitizedDelaySeconds(from: pluginDelayText)

        pluginRunning = true
        pluginCancelRequested = false
        pluginCurrentArchive = nil
        pluginLiveEvents = []
        pluginRunStatus = "Running plugin on \(arcids.count) archives…"
        appModel.activity.add(.init(kind: .action, title: "Plugin batch queued", detail: "\(pluginID) on \(arcids.count) archives"))
        appendPluginLiveEvent("Started \(pluginID) on \(arcids.count) archives")

        pluginTask?.cancel()
        pluginTask = Task {
            var ok = 0
            var fail = 0
            for (index, arcid) in arcids.enumerated() {
                if await MainActor.run(body: { pluginCancelRequested }) { break }
                await MainActor.run {
                    pluginCurrentArchive = displayName(for: arcid)
                    appendPluginLiveEvent("Processing \(displayName(for: arcid))")
                }
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

                if index + 1 < arcids.count && delaySeconds > 0 {
                    if await pauseBetweenPluginRuns(seconds: delaySeconds, done: index + 1, total: arcids.count, ok: ok, fail: fail) {
                        break
                    }
                }
            }

            let cancelledByRequest = await MainActor.run { pluginCancelRequested }

            await MainActor.run {
                pluginRunning = false
                pluginCurrentArchive = nil
                if cancelledByRequest {
                    pluginRunStatus = "Cancelled. Success \(ok), failed \(fail)."
                } else {
                    pluginRunStatus = "Done. Success \(ok), failed \(fail)."
                }
                pluginCancelRequested = false
                pluginTask = nil
            }

            if cancelledByRequest {
                appModel.activity.add(.init(kind: .warning, title: "Plugin batch cancelled", detail: "\(pluginID)"))
            }
        }
    }

    private func requestPluginCancel() {
        guard pluginRunning, !pluginCancelRequested else { return }
        pluginCancelRequested = true
        pluginRunStatus = "Stopping after current archive operation finishes…"
        appModel.activity.add(.init(kind: .warning, title: "Plugin batch cancel requested"))
    }

    private var selectedArcidsSorted: [String] {
        Array(appModel.selection.arcids).sorted()
    }

    private func displayName(for arcid: String) -> String {
        selectedArchiveNames[arcid] ?? arcid
    }

    private func refreshSelectedArchiveNames() {
        selectedNamesTask?.cancel()
        guard let profile = appModel.selectedProfile else {
            selectedArchiveNames = [:]
            return
        }
        let arcids = selectedArcidsSorted
        let keep = Set(arcids)
        selectedArchiveNames = selectedArchiveNames.filter { keep.contains($0.key) }

        selectedNamesTask = Task {
            for arcid in arcids where !Task.isCancelled {
                if selectedArchiveNames[arcid] != nil { continue }
                do {
                    let meta = try await appModel.archives.metadata(profile: profile, arcid: arcid)
                    let display = archiveDisplayName(metadata: meta, arcid: arcid)
                    await MainActor.run {
                        if appModel.selection.contains(arcid) {
                            selectedArchiveNames[arcid] = display
                        }
                    }
                } catch {
                    await MainActor.run {
                        if appModel.selection.contains(arcid) {
                            selectedArchiveNames[arcid] = arcid
                        }
                    }
                }
            }
        }
    }

    private func archiveDisplayName(metadata: ArchiveMetadata, arcid: String) -> String {
        let filename = (metadata.filename ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !filename.isEmpty { return filename }
        let title = (metadata.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return arcid
    }

    private func invalidatePreview() {
        previewTask?.cancel()
        previewTask = nil
        previewRows = []
        previewStatus = nil
    }

    private func generatePreview(sampleSize: Int = 10, executePlugin: Bool = false) {
        previewTask?.cancel()
        guard let profile = appModel.selectedProfile else { return }
        let arcids = Array(selectedArcidsSorted.prefix(sampleSize))
        guard !arcids.isEmpty else { return }

        let add = parseTags(addTagsText)
        let remove = parseTags(removeTagsText)
        let pluginID = selectedPluginID
        let delaySeconds = sanitizedDelaySeconds(from: pluginDelayText)
        let hasTagOps = !add.isEmpty || !remove.isEmpty
        let hasPluginOp = pluginID != nil

        previewRunning = true
        previewRows = []
        previewStatus = "Generating preview for \(arcids.count) archives…"

        previewTask = Task {
            var rows: [BatchPreviewRow] = []

            for arcid in arcids where !Task.isCancelled {
                do {
                    let meta = try await appModel.archives.metadata(profile: profile, arcid: arcid)
                    let filename = archiveDisplayName(metadata: meta, arcid: arcid)
                    await MainActor.run {
                        selectedArchiveNames[arcid] = filename
                    }

                    let originalTitle = (meta.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let originalTags = (meta.tags ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let originalSummary = (meta.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                    var previewTitle = originalTitle
                    var previewTags = originalTags
                    var previewSummary = originalSummary
                    var details: [String] = []
                    if hasTagOps {
                        previewTags = applyTagEdits(old: previewTags, add: add, remove: remove)
                    }
                    if let pluginID {
                        let pluginArg = pluginArgText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if pluginArg.isEmpty {
                            details.append("Plugin \(pluginID) selected.")
                        } else {
                            details.append("Plugin \(pluginID) arg: \(pluginArg)")
                        }

                        if executePlugin {
                            let raw = try await pluginsVM.run(
                                profile: profile,
                                pluginID: pluginID,
                                arcid: arcid,
                                arg: pluginArgText
                            )
                            if let patch = parsePluginMetadataPatch(from: raw) {
                                let applied = applyPluginPatch(
                                    patch,
                                    currentTitle: previewTitle,
                                    currentTags: previewTags,
                                    currentSummary: previewSummary,
                                    mode: pluginApplyMode
                                )
                                previewTitle = applied.title
                                previewTags = applied.tags
                                previewSummary = applied.summary
                            }
                            details.append("Plugin preview executed without saving.")
                        } else {
                            details.append("Plugin output not fetched in this preview.")
                        }
                    }

                    details.append(contentsOf: summarizeMetadataChanges(
                        beforeTitle: originalTitle,
                        beforeTags: originalTags,
                        beforeSummary: originalSummary,
                        afterTitle: previewTitle,
                        afterTags: previewTags,
                        afterSummary: previewSummary
                    ))

                    rows.append(.init(
                        arcid: arcid,
                        filename: filename,
                        detail: details.joined(separator: "\n"),
                        kind: .normal
                    ))
                } catch {
                    rows.append(.init(
                        arcid: arcid,
                        filename: arcid,
                        detail: "Preview failed: \(ErrorPresenter.short(error))",
                        kind: .error
                    ))
                }
            }

            await MainActor.run {
                previewRows = rows
                previewRunning = false
                let suffix = selectedArcidsSorted.count > sampleSize ? " (sample of \(sampleSize))" : ""
                if !hasTagOps && !hasPluginOp {
                    previewStatus = "Preview generated\(suffix), but no operations are currently configured."
                } else if hasPluginOp {
                    previewStatus = "Preview generated for \(rows.count) archives\(suffix). Plugin delay between runs: \(delayDisplay(delaySeconds))s."
                } else {
                    previewStatus = "Preview generated for \(rows.count) archives\(suffix)."
                }
            }
        }
    }

    private func refreshMetadataAfterPluginBatch(
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

    private func applyMetadataFromPluginOutputBatch(
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

    private func parsePluginMetadataPatch(from response: String) -> (title: String?, tags: String?, summary: String?)? {
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

    private func metadataSignature(title: String, tags: String, summary: String) -> String {
        [
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizeTags(tags),
            summary.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "|||")
    }

    private func mergeTagCSV(base: String, additions: String) -> String {
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

    private var selectedPlugin: PluginInfo? {
        guard let id = selectedPluginID else { return nil }
        return pluginsVM.plugins.first(where: { $0.id == id })
    }

    @ViewBuilder
    private func pluginOptionRow(_ param: PluginInfo.Parameter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let title = pluginOptionName(param)
            let fallbackValue = pluginOptionValueText(param)
            if pluginOptionIsBool(param), let boolValue = pluginBoolValue(param) {
                Toggle(isOn: .constant(boolValue)) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .disabled(true)
            } else {
                Text(title)
                    .font(.caption.weight(.semibold))
                TextField("", text: .constant(fallbackValue))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                    .font(.caption2.monospaced())
            }

            if let desc = param.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func pluginOptionName(_ param: PluginInfo.Parameter) -> String {
        let raw = param.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Option" : raw
    }

    private func pluginOptionValueText(_ param: PluginInfo.Parameter) -> String {
        let value = param.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty { return value }
        let fallback = param.defaultValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback
    }

    private func pluginOptionIsBool(_ param: PluginInfo.Parameter) -> Bool {
        let type = param.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if type == "bool" || type == "boolean" { return true }
        let v = pluginOptionValueText(param).lowercased()
        return v == "true" || v == "false" || v == "1" || v == "0" || v == "yes" || v == "no"
    }

    private func pluginBoolValue(_ param: PluginInfo.Parameter) -> Bool? {
        let v = pluginOptionValueText(param).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch v {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func applyDefaultPluginDelayFromSelection() {
        let seconds = defaultPluginDelaySeconds(for: selectedPlugin)
        pluginDelayText = delayDisplay(seconds)
    }

    private func defaultPluginDelaySeconds(for plugin: PluginInfo?) -> Double {
        guard let plugin else { return 4 }
        let candidates = plugin.parameters.filter { param in
            let id = param.id.lowercased()
            let name = (param.name ?? "").lowercased()
            return id.contains("delay") || id.contains("sleep") || id.contains("wait")
                || name.contains("delay") || name.contains("sleep") || name.contains("wait")
        }

        for param in candidates {
            let raw = pluginOptionValueText(param)
            let value = sanitizedDelaySeconds(from: raw)
            if value > 0 || raw.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
                return value
            }
        }
        return 4
    }

    private func sanitizedDelaySeconds(from raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), parsed.isFinite else { return 0 }
        return max(0, parsed)
    }

    private func delayDisplay(_ seconds: Double) -> String {
        if seconds.rounded() == seconds {
            return String(Int(seconds))
        }
        return String(format: "%.2f", seconds)
    }

    private func pauseBetweenPluginRuns(
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

    private func applyPluginPatch(
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

    private func summarizeMetadataChanges(
        beforeTitle: String,
        beforeTags: String,
        beforeSummary: String,
        afterTitle: String,
        afterTags: String,
        afterSummary: String
    ) -> [String] {
        var lines: [String] = []
        if beforeTitle != afterTitle {
            lines.append("Title: \(previewText(beforeTitle)) -> \(previewText(afterTitle))")
        }
        if normalizeTags(beforeTags) != normalizeTags(afterTags) {
            lines.append("Tags: \(previewText(beforeTags)) -> \(previewText(afterTags))")
        }
        if beforeSummary != afterSummary {
            lines.append("Summary: \(previewText(beforeSummary)) -> \(previewText(afterSummary))")
        }
        if lines.isEmpty {
            lines.append("No metadata changes.")
        }
        return lines
    }

    private func previewText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : trimmed
    }

    private func metadataChangeLiveMessage(
        prefix: String,
        arcid: String,
        beforeTitle: String,
        beforeTags: String,
        beforeSummary: String,
        afterTitle: String,
        afterTags: String,
        afterSummary: String
    ) -> String {
        let lines = summarizeMetadataChanges(
            beforeTitle: beforeTitle,
            beforeTags: beforeTags,
            beforeSummary: beforeSummary,
            afterTitle: afterTitle,
            afterTags: afterTags,
            afterSummary: afterSummary
        ).map { truncatedLiveField($0) }

        if lines.count == 1, lines[0] == "No metadata changes." {
            return "\(prefix) \(displayName(for: arcid)) • No metadata changes."
        }
        return "\(prefix) \(displayName(for: arcid)) • \(lines.joined(separator: " | "))"
    }

    private func truncatedLiveField(_ value: String, maxLength: Int = 180) -> String {
        let compact = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > maxLength else { return compact }
        let end = compact.index(compact.startIndex, offsetBy: maxLength - 1)
        return String(compact[..<end]) + "…"
    }

    private func uniqueTagCSV(_ value: String) -> String {
        var out: [String] = []
        var seen: Set<String> = []
        for tag in parseTags(value) {
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                out.append(tag)
            }
        }
        return out.joined(separator: ", ")
    }

    private func appendBatchLiveEvent(_ message: String) {
        let entry = "[\(timeStamp())] \(message)"
        batchLiveEvents.insert(entry, at: 0)
        if batchLiveEvents.count > 120 {
            batchLiveEvents.removeLast(batchLiveEvents.count - 120)
        }
    }

    private func appendPluginLiveEvent(_ message: String) {
        let entry = "[\(timeStamp())] \(message)"
        pluginLiveEvents.insert(entry, at: 0)
        if pluginLiveEvents.count > 160 {
            pluginLiveEvents.removeLast(pluginLiveEvents.count - 160)
        }
    }

    private func timeStamp() -> String {
        Self.liveTimeFormatter.string(from: Date())
    }

    private static let liveTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var running: Bool {
        get { runState.running }
        nonmutating set { runState.running = newValue }
    }

    private var batchCancelRequested: Bool {
        get { runState.batchCancelRequested }
        nonmutating set { runState.batchCancelRequested = newValue }
    }

    private var progressText: String? {
        get { runState.progressText }
        nonmutating set { runState.progressText = newValue }
    }

    private var errors: [String] {
        get { runState.errors }
        nonmutating set { runState.errors = newValue }
    }

    private var task: Task<Void, Never>? {
        get { runState.task }
        nonmutating set { runState.task = newValue }
    }

    private var batchCurrentArchive: String? {
        get { runState.batchCurrentArchive }
        nonmutating set { runState.batchCurrentArchive = newValue }
    }

    private var batchLiveEvents: [String] {
        get { runState.batchLiveEvents }
        nonmutating set { runState.batchLiveEvents = newValue }
    }

    private var pluginRunning: Bool {
        get { runState.pluginRunning }
        nonmutating set { runState.pluginRunning = newValue }
    }

    private var pluginCancelRequested: Bool {
        get { runState.pluginCancelRequested }
        nonmutating set { runState.pluginCancelRequested = newValue }
    }

    private var pluginRunStatus: String? {
        get { runState.pluginRunStatus }
        nonmutating set { runState.pluginRunStatus = newValue }
    }

    private var pluginTask: Task<Void, Never>? {
        get { runState.pluginTask }
        nonmutating set { runState.pluginTask = newValue }
    }

    private var pluginCurrentArchive: String? {
        get { runState.pluginCurrentArchive }
        nonmutating set { runState.pluginCurrentArchive = newValue }
    }

    private var pluginLiveEvents: [String] {
        get { runState.pluginLiveEvents }
        nonmutating set { runState.pluginLiveEvents = newValue }
    }
}

@MainActor
private final class BatchRunState: ObservableObject {
    static let shared = BatchRunState()

    @Published var running: Bool = false
    @Published var batchCancelRequested: Bool = false
    @Published var progressText: String?
    @Published var errors: [String] = []
    var task: Task<Void, Never>?
    @Published var batchCurrentArchive: String?
    @Published var batchLiveEvents: [String] = []

    @Published var pluginRunning: Bool = false
    @Published var pluginCancelRequested: Bool = false
    @Published var pluginRunStatus: String?
    var pluginTask: Task<Void, Never>?
    @Published var pluginCurrentArchive: String?
    @Published var pluginLiveEvents: [String] = []
}

private struct BatchPreviewRow: Identifiable {
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

private enum PluginApplyMode: String, CaseIterable {
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
