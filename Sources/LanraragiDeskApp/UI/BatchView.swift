import SwiftUI

struct BatchView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var addTagsText: String = ""
    @State private var removeTagsText: String = ""
    @State private var running: Bool = false
    @State private var progressText: String?
    @State private var errors: [String] = []
    @State private var task: Task<Void, Never>?

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
                        .disabled(running)
                    TextField("Remove tags (comma separated)", text: $removeTagsText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(running)

                    HStack {
                        Button(running ? "Running…" : "Run") {
                            run()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || appModel.selection.count == 0 || (parseTags(addTagsText).isEmpty && parseTags(removeTagsText).isEmpty))

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
}
