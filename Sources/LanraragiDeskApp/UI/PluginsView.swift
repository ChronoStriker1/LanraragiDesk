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
                if vm.isLoading {
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

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(18)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
}

