import SwiftUI
import LanraragiKit

struct PluginsView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var vm = PluginsViewModel()

    @State private var selectedPluginID: String?
    @State private var argText: String = ""
    @State private var running: Bool = false
    @State private var runStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Plugins")
                    .font(.title2)
                    .bold()
                Spacer()
                if vm.isLoading || vm.isPollingJobs {
                    ProgressView()
                }
                Button("Refresh") {
                    Task { await reload() }
                }
            }

            if let s = vm.statusText {
                Text(s)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Run on selection")
                    .font(.headline)

                Text("\(appModel.selection.count) selected in Library")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker("Plugin", selection: $selectedPluginID) {
                    Text("Select plugin").tag(Optional<String>.none)
                    ForEach(vm.plugins, id: \.id) { p in
                        Text(p.title).tag(Optional(p.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(vm.plugins.isEmpty || running)

                if let plugin = selectedPlugin {
                    if let d = plugin.description, !d.isEmpty {
                        Text(d)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Settings / Options")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 2)

                    if plugin.parameters.isEmpty {
                        Text("No plugin settings/options exposed by the server.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(plugin.parameters) { param in
                                    optionRow(param)
                                }
                            }
                        }
                        .frame(minHeight: 80, maxHeight: 170)
                    }
                }

                TextField(selectedPlugin?.oneshotArg ?? "Plugin arg (optional)", text: $argText)
                    .textFieldStyle(.roundedBorder)

                Text("Plugin options are reported by LANraragi and applied server-side.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(running ? "Queueing…" : "Queue") {
                        queueSelected()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || selectedPluginID == nil || appModel.selection.count == 0)

                    Spacer()
                }

                if let runStatus {
                    Text(runStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()
                    .padding(.vertical, 4)

                HStack {
                    Text("Job Status")
                        .font(.headline)
                    Spacer()
                    Button("Refresh Status") {
                        Task { await refreshJobStatuses() }
                    }
                    .disabled(vm.jobs.isEmpty)
                    Button("Clear Finished") {
                        vm.clearTerminalJobs()
                    }
                    .disabled(!vm.hasTerminalJobs)
                }

                HStack(spacing: 8) {
                    statusBadge(title: "Running", count: vm.runningCount, color: .orange)
                    statusBadge(title: "Finished", count: vm.finishedCount, color: .green)
                    statusBadge(title: "Failed", count: vm.failedCount, color: .red)
                    Spacer()
                }

                if vm.jobs.isEmpty {
                    Text("No queued plugin jobs yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    List(vm.jobs) { row in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(stateColor(row.state))
                                .frame(width: 9, height: 9)
                                .padding(.top, 5)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.pluginID)
                                    .font(.callout.weight(.semibold))
                                    .lineLimit(1)

                                Text(row.arcid)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)

                                Text("Job \(row.jobID) • \(row.state.label)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)

                                if let rawState = row.rawState, !rawState.isEmpty {
                                    Text("Server state: \(rawState)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                if let err = row.lastError, !err.isEmpty {
                                    Text(err)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                        .lineLimit(2)
                                }
                            }

                            Spacer(minLength: 0)

                            Text(row.lastUpdated, style: .time)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                    .listStyle(.plain)
                    .frame(minHeight: 180, maxHeight: 300)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(18)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .debugFrameNumber(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task {
            await reload()
        }
    }

    private func reload() async {
        guard let profile = appModel.selectedProfile else { return }
        await vm.load(profile: profile)
        if let selectedPluginID, vm.plugins.contains(where: { $0.id == selectedPluginID }) {
            return
        }
        selectedPluginID = vm.plugins.first?.id
    }

    private func refreshJobStatuses() async {
        guard let profile = appModel.selectedProfile else { return }
        await vm.refreshJobStatuses(profile: profile)
    }

    private func queueSelected() {
        guard let profile = appModel.selectedProfile else { return }
        guard let pluginID = selectedPluginID else { return }
        let arcids = Array(appModel.selection.arcids).sorted()
        guard !arcids.isEmpty else { return }

        running = true
        runStatus = "Queueing \(arcids.count) jobs…"
        appModel.activity.add(.init(kind: .action, title: "Plugin queued", detail: "\(pluginID) on \(arcids.count) archives"))

        Task {
            var ok = 0
            var fail = 0
            for arcid in arcids {
                if Task.isCancelled { break }
                do {
                    let job = try await vm.queue(profile: profile, pluginID: pluginID, arcid: arcid, arg: argText)
                    vm.trackQueuedJob(profile: profile, pluginID: pluginID, arcid: arcid, jobID: job.job)
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
                    runStatus = "Queued \(ok) • Failed \(fail)…"
                }
            }
            await MainActor.run {
                running = false
                runStatus = "Done. Queued \(ok), failed \(fail)."
            }
        }
    }

    @ViewBuilder
    private func statusBadge(title: String, count: Int, color: Color) -> some View {
        Text("\(title) \(count)")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func stateColor(_ state: PluginsViewModel.TrackedPluginJob.State) -> Color {
        switch state {
        case .queued:
            return .yellow
        case .running:
            return .orange
        case .finished:
            return .green
        case .failed:
            return .red
        case .unknown:
            return .secondary
        }
    }

    private var selectedPlugin: PluginInfo? {
        guard let id = selectedPluginID else { return nil }
        return vm.plugins.first(where: { $0.id == id })
    }

    @ViewBuilder
    private func optionRow(_ param: PluginInfo.Parameter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(optionName(param))
                    .font(.caption.weight(.semibold))
                if let type = param.type, !type.isEmpty {
                    Text(type)
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(Capsule())
                }
            }

            if let value = param.value, !value.isEmpty {
                Text("Current: \(value)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let fallback = param.defaultValue, !fallback.isEmpty {
                Text("Default: \(fallback)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let desc = param.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func optionName(_ param: PluginInfo.Parameter) -> String {
        if let name = param.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Option"
    }
}
