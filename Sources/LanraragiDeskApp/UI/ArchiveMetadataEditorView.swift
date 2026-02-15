import SwiftUI
import LanraragiKit

struct ArchiveMetadataEditorView: View {
    let profile: Profile
    let arcid: String
    let initialMeta: ArchiveMetadata?
    let archives: ArchiveLoader
    let onSaved: (ArchiveMetadata) -> Void

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading: Bool = false
    @State private var errorText: String?

    @State private var title: String = ""
    @State private var tags: String = ""
    @State private var summary: String = ""
    @State private var tagQuery: String = ""
    @State private var tagSuggestions: [TagSuggestionStore.Suggestion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Edit Metadata")
                    .font(.title2)
                    .bold()
                Spacer()
                Text(arcid)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let errorText {
                Text("Error: \(errorText)")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Form {
                TextField("Title", text: $title)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        TextField("Add tag…", text: $tagQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addTagFromQuery() }

                        Button("Add") { addTagFromQuery() }
                            .disabled(tagQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if !tagSuggestions.isEmpty {
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(tagSuggestions.prefix(12), id: \.value) { s in
                                    Button {
                                        tagQuery = s.value
                                        addTagFromQuery()
                                    } label: {
                                        HStack {
                                            Text(s.value)
                                                .font(.callout)
                                            Spacer()
                                            Text("\(s.weight)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 10)
                                        .background(.quaternary.opacity(0.35))
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .frame(maxHeight: 140)
                    }

                    TextEditor(text: $tags)
                        .font(.body)
                        .frame(minHeight: 90)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                        }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $summary)
                        .font(.body)
                        .frame(minHeight: 90)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                        }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isLoading ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .task {
            await loadIfNeeded()
        }
        .onChange(of: tagQuery) { _, _ in
            Task { await refreshSuggestions() }
        }
    }

    private func loadIfNeeded() async {
        if let m = initialMeta {
            apply(meta: m)
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let m = try await archives.metadata(profile: profile, arcid: arcid)
            apply(meta: m)
        } catch {
            if Task.isCancelled { return }
            errorText = ErrorPresenter.short(error)
        }
    }

    private func apply(meta: ArchiveMetadata) {
        title = (meta.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        tags = (meta.tags ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        summary = (meta.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() async {
        errorText = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let updated = try await archives.updateMetadata(
                profile: profile,
                arcid: arcid,
                title: title,
                tags: tags,
                summary: summary
            )
            onSaved(updated)
            appModel.activity.add(.init(kind: .action, title: "Updated metadata", detail: arcid))
            dismiss()
        } catch {
            if Task.isCancelled { return }
            errorText = ErrorPresenter.short(error)
            appModel.activity.add(.init(kind: .error, title: "Metadata update failed", detail: "\(arcid)\n\(error)"))
        }
    }

    private func addTagFromQuery() {
        let t = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        var parts = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !parts.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            parts.append(t)
        }
        tags = parts.joined(separator: ", ")
        tagQuery = ""
        tagSuggestions = []
    }

    private func refreshSuggestions() async {
        let q = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            await MainActor.run { tagSuggestions = [] }
            return
        }

        let minWeight = UserDefaults.standard.integer(forKey: "tags.minWeight")
        let ttlHours = max(1, UserDefaults.standard.integer(forKey: "tags.ttlHours"))
        let settings = TagSuggestionStore.Settings(minWeight: minWeight, ttlSeconds: ttlHours * 60 * 60)

        let sugg = await appModel.tagSuggestions.suggestions(profile: profile, settings: settings, prefix: q, limit: 20)
        await MainActor.run { tagSuggestions = sugg }
    }
}
