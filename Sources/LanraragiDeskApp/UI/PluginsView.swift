import SwiftUI

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

            HStack(spacing: 14) {
                List(selection: $selectedPluginID) {
                    ForEach(vm.plugins, id: \.id) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.title)
                                .font(.callout)
                            if let d = p.description, !d.isEmpty {
                                Text(d)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .tag(p.id)
                    }
                }
                .frame(minWidth: 320)
                .debugFrameNumber(1)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Run on selection")
                        .font(.headline)

                    Text("\(appModel.selection.count) selected in Library")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    TextField("Plugin arg (optional)", text: $argText)
                        .textFieldStyle(.roundedBorder)

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
                    appModel.activity.add(.init(kind: .action, title: "Plugin job queued", detail: "\(pluginID) • \(arcid) • job \(job.job)"))
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
}
