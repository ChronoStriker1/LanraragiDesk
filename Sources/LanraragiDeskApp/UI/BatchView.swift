import SwiftUI
import LanraragiKit

struct BatchView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var pluginsVM = PluginsViewModel()

    @State private var addTagsText: String = ""
    @State private var removeTagsText: String = ""
    @State private var running: Bool = false
    @State private var progressText: String?
    @State private var errors: [String] = []
    @State private var task: Task<Void, Never>?
    @State private var selectedPluginID: String?
    @State private var pluginArgText: String = ""
    @State private var pluginRunning: Bool = false
    @State private var pluginRunStatus: String?
    @State private var showPluginSettings: Bool = false

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
                    .disabled(appModel.selection.count == 0 || running)
            }

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

                        Button("Cancel", role: .destructive) {
                            task?.cancel()
                            task = nil
                            running = false
                            progressText = "Cancelled."
                            appModel.activity.add(.init(kind: .warning, title: "Batch cancelled"))
                        }
                        .disabled(!running)

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
                        Button(pluginRunning ? "Queueing…" : "Queue Plugin") {
                            runPluginBatch()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || pluginRunning || selectedPluginID == nil || appModel.selection.count == 0)

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
            task?.cancel()
        }
        .task(id: appModel.selectedProfileID) {
            await loadPlugins()
        }
    }

    private func run() {
        guard let profile = appModel.selectedProfile else { return }
        let add = parseTags(addTagsText)
        let remove = parseTags(removeTagsText)
        let arcids = Array(appModel.selection.arcids).sorted()
        if arcids.isEmpty { return }

        running = true
        errors = []
        progressText = "Starting…"
        appModel.activity.add(.init(kind: .action, title: "Batch started", detail: "\(arcids.count) archives"))

        task?.cancel()
        task = Task {
            var done = 0
            for arcid in arcids {
                if Task.isCancelled { break }
                do {
                    let meta = try await appModel.archives.metadata(profile: profile, arcid: arcid)
                    let oldTags = meta.tags ?? ""
                    let newTags = applyTagEdits(old: oldTags, add: add, remove: remove)
                    if normalizeTags(oldTags) == normalizeTags(newTags) {
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
                } catch {
                    let msg = "\(arcid): \(ErrorPresenter.short(error))"
                    await MainActor.run { errors.append(msg) }
                }

                done += 1
                await MainActor.run {
                    progressText = "Processed \(done)/\(arcids.count)…"
                }
            }

            await MainActor.run {
                running = false
                if Task.isCancelled {
                    progressText = "Cancelled."
                } else if errors.isEmpty {
                    progressText = "Done."
                } else {
                    progressText = "Done with \(errors.count) errors."
                }
                task = nil
            }

            if Task.isCancelled {
                appModel.activity.add(.init(kind: .warning, title: "Batch cancelled"))
            } else if errors.isEmpty {
                appModel.activity.add(.init(kind: .action, title: "Batch completed", detail: "\(arcids.count) archives"))
            } else {
                appModel.activity.add(.init(kind: .warning, title: "Batch completed with errors", detail: "\(errors.count) errors"))
            }
        }
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
            return
        }
        selectedPluginID = pluginsVM.plugins.first?.id
    }

    private func runPluginBatch() {
        guard let profile = appModel.selectedProfile else { return }
        guard let pluginID = selectedPluginID else { return }
        let arcids = Array(appModel.selection.arcids).sorted()
        guard !arcids.isEmpty else { return }

        pluginRunning = true
        pluginRunStatus = "Queueing \(arcids.count) plugin jobs…"
        appModel.activity.add(.init(kind: .action, title: "Plugin batch queued", detail: "\(pluginID) on \(arcids.count) archives"))

        Task {
            var ok = 0
            var fail = 0
            for arcid in arcids {
                if Task.isCancelled { break }
                do {
                    let job = try await pluginsVM.queue(profile: profile, pluginID: pluginID, arcid: arcid, arg: pluginArgText)
                    pluginsVM.trackQueuedJob(profile: profile, pluginID: pluginID, arcid: arcid, jobID: job.job)
                    ok += 1
                    let detail = job.job > 0
                        ? "\(pluginID) • \(arcid) • job \(job.job)"
                        : "\(pluginID) • \(arcid) • queued (no job id returned)"
                    appModel.activity.add(.init(kind: .action, title: "Plugin job queued", detail: detail))
                } catch {
                    fail += 1
                    appModel.activity.add(.init(kind: .error, title: "Plugin queue failed", detail: "\(pluginID) • \(arcid)\n\(error)"))
                }
                await MainActor.run {
                    pluginRunStatus = "Queued \(ok) • Failed \(fail)…"
                }
            }

            await MainActor.run {
                pluginRunning = false
                pluginRunStatus = "Done. Queued \(ok), failed \(fail)."
            }
        }
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
}
