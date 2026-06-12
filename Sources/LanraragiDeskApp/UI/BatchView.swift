import Foundation
import SwiftUI
import LanraragiKit

struct BatchView: View {
    @EnvironmentObject var appModel: AppModel
    @StateObject var pluginsVM = PluginsViewModel()
    @StateObject var runState = BatchRunState.shared

    @State var addTagsText: String = ""
    @State var removeTagsText: String = ""
    @State var selectedPluginID: String?
    @State var pluginArgText: String = ""
    @State var pluginDelayText: String = "4"
    @State var pluginApplyMode: PluginApplyMode = .mergeWithExisting
    @State var showPluginSettings: Bool = false
    @State var selectedArchiveNames: [String: String] = [:]
    @State var selectedNamesTask: Task<Void, Never>?
    @State var previewRows: [BatchPreviewRow] = []
    @State var previewStatus: String?
    @State var previewRunning: Bool = false
    @State var previewTask: Task<Void, Never>?
    @State var previewBeforeQueue: Bool = true
    @State var resumableTagBatch: TagBatchCheckpoint?
    @State var resumablePluginBatch: PluginBatchCheckpoint?
    @State var restoredTagCheckpointUI: Bool = false
    @State var restoredPluginCheckpointUI: Bool = false

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

            if let profile = appModel.selectedProfile {
                FindArchivesCard(profile: profile)
                    .environmentObject(appModel)
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

            if previewBeforeQueue || previewRunning || !previewRows.isEmpty || previewStatus != nil {
                GroupBox("Preview") {
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
            }

            GroupBox("Tag operations") {
                VStack(alignment: .leading, spacing: 12) {
                    if let checkpoint = resumableTagBatch, !running {
                        HStack(spacing: 8) {
                            Text(tagCheckpointBannerText(checkpoint))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Resume Queue") {
                                resumeTagBatchFromCheckpoint()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(running || pluginRunning || previewRunning)
                            Button("Discard") {
                                clearTagBatchCheckpoint()
                                refreshResumableTagBatch()
                            }
                            .disabled(running || pluginRunning)
                            Spacer()
                        }
                    }

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

                        Button(batchPauseRequested ? "Pausing…" : "Pause") {
                            requestBatchPause()
                        }
                        .disabled(!running || batchPauseRequested)

                        Spacer()
                    }

                    if let progressText {
                        Text(progressText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
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

                    if let checkpoint = resumablePluginBatch, !pluginRunning {
                        HStack(spacing: 8) {
                            Text(pluginCheckpointBannerText(checkpoint))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Resume Queue") {
                                resumePluginBatchFromCheckpoint()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(running || pluginRunning || previewRunning)
                            Button("Discard") {
                                clearPluginBatchCheckpoint()
                                refreshResumablePluginBatch()
                            }
                            .disabled(running || pluginRunning)
                            Spacer()
                        }
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

                        Button(pluginRunning ? "Queueing…" : "Queue Batch") {
                            runPluginBatch()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || pluginRunning || previewRunning || selectedPluginID == nil || appModel.selection.count == 0)

                        Button(pluginCancelRequested ? "Stopping…" : "Cancel", role: .destructive) {
                            requestPluginCancel()
                        }
                        .disabled(!pluginRunning || pluginCancelRequested)

                        Button(pluginPauseRequested ? "Pausing…" : "Pause") {
                            requestPluginPause()
                        }
                        .disabled(!pluginRunning || pluginPauseRequested)

                        Spacer()
                    }

                    if let pluginRunStatus {
                        Text(pluginRunStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }
            .debugFrameNumber(4)

            GroupBox("Live log") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if let batchCurrentArchive, running {
                            Text("Tag batch: \(batchCurrentArchive)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let pluginCurrentArchive, pluginRunning {
                            Text("Plugin batch: \(pluginCurrentArchive)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Clear") {
                            batchLiveEvents = []
                            pluginLiveEvents = []
                            liveEvents = []
                            errors = []
                        }
                        .disabled(liveEvents.isEmpty && errors.isEmpty)
                    }

                    if liveEvents.isEmpty && errors.isEmpty {
                        Text("No live events yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(liveEvents, id: \.self) { event in
                                    Text(event)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                ForEach(errors, id: \.self) { e in
                                    Text("[ERROR] \(e)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.trailing, 4)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .debugFrameNumber(3)
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
            refreshResumableTagBatch()
            refreshResumablePluginBatch()
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
    var selectedArcidsSorted: [String] {
        Array(appModel.selection.arcids).sorted()
    }

    func displayName(for arcid: String) -> String {
        selectedArchiveNames[arcid] ?? arcid
    }

    func refreshSelectedArchiveNames() {
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

    func archiveDisplayName(metadata: ArchiveMetadata, arcid: String) -> String {
        let filename = (metadata.filename ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !filename.isEmpty { return filename }
        let title = (metadata.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return arcid
    }

    func invalidatePreview() {
        previewTask?.cancel()
        previewTask = nil
        previewRows = []
        previewStatus = nil
    }

    func generatePreview(sampleSize: Int = 10, executePlugin: Bool = false) {
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
                        if executePlugin {
                            appendPluginLiveEvent("Previewing \(filename)")
                        }
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
                    if executePlugin {
                        await MainActor.run {
                            appendPluginLiveEvent(metadataChangeLiveMessage(
                                prefix: "Preview",
                                arcid: arcid,
                                beforeTitle: originalTitle,
                                beforeTags: originalTags,
                                beforeSummary: originalSummary,
                                afterTitle: previewTitle,
                                afterTags: previewTags,
                                afterSummary: previewSummary
                            ))
                        }
                    }
                } catch {
                    rows.append(.init(
                        arcid: arcid,
                        filename: arcid,
                        detail: "Preview failed: \(ErrorPresenter.short(error))",
                        kind: .error
                    ))
                    if executePlugin {
                        await MainActor.run {
                            appendPluginLiveEvent("Preview failed for \(displayName(for: arcid)): \(ErrorPresenter.short(error))")
                        }
                    }
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
                if executePlugin {
                    appendPluginLiveEvent("Preview completed for \(rows.count) archives\(suffix)")
                    pluginRunStatus = "Preview complete for \(rows.count) archives\(suffix)."
                }
            }
        }
    }
    var selectedPlugin: PluginInfo? {
        guard let id = selectedPluginID else { return nil }
        return pluginsVM.plugins.first(where: { $0.id == id })
    }

    @ViewBuilder
    func pluginOptionRow(_ param: PluginInfo.Parameter) -> some View {
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

    func pluginOptionName(_ param: PluginInfo.Parameter) -> String {
        let raw = param.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "Option" : raw
    }

    func pluginOptionValueText(_ param: PluginInfo.Parameter) -> String {
        let value = param.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty { return value }
        let fallback = param.defaultValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback
    }

    func pluginOptionIsBool(_ param: PluginInfo.Parameter) -> Bool {
        let type = param.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if type == "bool" || type == "boolean" { return true }
        let v = pluginOptionValueText(param).lowercased()
        return v == "true" || v == "false" || v == "1" || v == "0" || v == "yes" || v == "no"
    }

    func pluginBoolValue(_ param: PluginInfo.Parameter) -> Bool? {
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

    func applyDefaultPluginDelayFromSelection() {
        let seconds = defaultPluginDelaySeconds(for: selectedPlugin)
        pluginDelayText = delayDisplay(seconds)
    }

    func defaultPluginDelaySeconds(for plugin: PluginInfo?) -> Double {
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

    func sanitizedDelaySeconds(from raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), parsed.isFinite else { return 0 }
        return max(0, parsed)
    }

    func delayDisplay(_ seconds: Double) -> String {
        if seconds.rounded() == seconds {
            return String(Int(seconds))
        }
        return String(format: "%.2f", seconds)
    }
    func summarizeMetadataChanges(
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

    func previewText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : trimmed
    }

    func metadataChangeLiveMessage(
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
        )

        if lines.count == 1, lines[0] == "No metadata changes." {
            return "\(prefix) \(displayName(for: arcid)) • No metadata changes."
        }
        return "\(prefix) \(displayName(for: arcid)) • \(lines.joined(separator: " | "))"
    }

    func uniqueTagCSV(_ value: String) -> String {
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

    func appendBatchLiveEvent(_ message: String) {
        let entry = "[\(timeStamp())] \(message)"
        batchLiveEvents.insert(entry, at: 0)
        liveEvents.insert("[\(timeStamp())] [TAG] \(message)", at: 0)
    }

    func appendPluginLiveEvent(_ message: String) {
        let entry = "[\(timeStamp())] \(message)"
        pluginLiveEvents.insert(entry, at: 0)
        liveEvents.insert("[\(timeStamp())] [PLUGIN] \(message)", at: 0)
    }

    func timeStamp() -> String {
        Self.liveTimeFormatter.string(from: Date())
    }

    static let liveTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var running: Bool {
        get { runState.running }
        nonmutating set { runState.running = newValue }
    }

    var batchCancelRequested: Bool {
        get { runState.batchCancelRequested }
        nonmutating set { runState.batchCancelRequested = newValue }
    }

    var batchPauseRequested: Bool {
        get { runState.batchPauseRequested }
        nonmutating set { runState.batchPauseRequested = newValue }
    }

    var batchPaused: Bool {
        get { runState.batchPaused }
        nonmutating set { runState.batchPaused = newValue }
    }

    var progressText: String? {
        get { runState.progressText }
        nonmutating set { runState.progressText = newValue }
    }

    var errors: [String] {
        get { runState.errors }
        nonmutating set { runState.errors = newValue }
    }

    var task: Task<Void, Never>? {
        get { runState.task }
        nonmutating set { runState.task = newValue }
    }

    var batchCurrentArchive: String? {
        get { runState.batchCurrentArchive }
        nonmutating set { runState.batchCurrentArchive = newValue }
    }

    var batchLiveEvents: [String] {
        get { runState.batchLiveEvents }
        nonmutating set { runState.batchLiveEvents = newValue }
    }

    var pluginRunning: Bool {
        get { runState.pluginRunning }
        nonmutating set { runState.pluginRunning = newValue }
    }

    var pluginCancelRequested: Bool {
        get { runState.pluginCancelRequested }
        nonmutating set { runState.pluginCancelRequested = newValue }
    }

    var pluginPauseRequested: Bool {
        get { runState.pluginPauseRequested }
        nonmutating set { runState.pluginPauseRequested = newValue }
    }

    var pluginPaused: Bool {
        get { runState.pluginPaused }
        nonmutating set { runState.pluginPaused = newValue }
    }

    var pluginRunStatus: String? {
        get { runState.pluginRunStatus }
        nonmutating set { runState.pluginRunStatus = newValue }
    }

    var pluginTask: Task<Void, Never>? {
        get { runState.pluginTask }
        nonmutating set { runState.pluginTask = newValue }
    }

    var pluginCurrentArchive: String? {
        get { runState.pluginCurrentArchive }
        nonmutating set { runState.pluginCurrentArchive = newValue }
    }

    var pluginLiveEvents: [String] {
        get { runState.pluginLiveEvents }
        nonmutating set { runState.pluginLiveEvents = newValue }
    }

    var liveEvents: [String] {
        get { runState.liveEvents }
        nonmutating set { runState.liveEvents = newValue }
    }
}
