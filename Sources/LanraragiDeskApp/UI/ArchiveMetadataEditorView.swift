import SwiftUI
import LanraragiKit

struct ArchiveMetadataEditorView: View {
    let profile: Profile
    let arcid: String
    let initialMeta: ArchiveMetadata?
    let archives: ArchiveLoader
    let onSaved: (ArchiveMetadata) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isLoading: Bool = false
    @State private var errorText: String?

    @State private var title: String = ""
    @State private var tags: String = ""
    @State private var summary: String = ""

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
            dismiss()
        } catch {
            if Task.isCancelled { return }
            errorText = ErrorPresenter.short(error)
        }
    }
}

