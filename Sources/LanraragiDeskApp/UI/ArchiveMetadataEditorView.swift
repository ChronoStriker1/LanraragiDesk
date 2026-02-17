import AppKit
import SwiftUI
import LanraragiKit

struct ArchiveMetadataEditorView: View {
    let profile: Profile
    let arcid: String
    let initialMeta: ArchiveMetadata?
    let archives: ArchiveLoader
    let onSaved: @MainActor (ArchiveMetadata) -> Void
    let onDelete: @MainActor (String) async throws -> Void

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pluginsVM = PluginsViewModel()

    @State private var isLoading: Bool = false
    @State private var errorText: String?

    @State private var title: String = ""
    @State private var tags: String = ""
    @State private var summary: String = ""
    @State private var loadedTitle: String = ""
    @State private var loadedTags: String = ""
    @State private var loadedSummary: String = ""
    @State private var tagQuery: String = ""
    @State private var tagSuggestions: [TagSuggestionStore.Suggestion] = []
    @State private var pageCount: Int = 0
    @State private var coverPage: Int = 1
    @State private var coverStatusText: String?
    @State private var isUpdatingCover: Bool = false
    @State private var isDeleting: Bool = false
    @State private var confirmDelete: Bool = false
    @State private var selectedPluginID: String?
    @State private var pluginArgText: String = ""
    @State private var pluginRunning: Bool = false
    @State private var pluginRunStatus: String?
    @State private var showPluginSettings: Bool = false
    @State private var showSummaryEditor: Bool = false

    private var groupedTags: [MetadataTagFormatter.Group] {
        MetadataTagFormatter.grouped(tags: tags)
    }

    private var coverPageRange: ClosedRange<Int> {
        1...max(1, pageCount)
    }

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

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Title", text: $title, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        DisclosureGroup(isExpanded: $showSummaryEditor) {
                            borderedTextEditor($summary, minHeight: 180)
                                .padding(.top, 4)
                        } label: {
                            HStack(spacing: 8) {
                                Text("Summary")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("empty")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cover")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Stepper(
                                "Use page \(coverPage) of \(max(1, pageCount))",
                                value: $coverPage,
                                in: coverPageRange
                            )
                            .disabled(pageCount <= 0)

                            Button(isUpdatingCover ? "Updating…" : "Set cover from page") {
                                Task { await setCoverFromPage() }
                            }
                            .disabled(isLoading || isUpdatingCover || pageCount <= 0)
                        }

                        if pageCount <= 0 {
                            Text("Page count unavailable for this archive.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let coverStatusText, !coverStatusText.isEmpty {
                            Text(coverStatusText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

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

                        HStack {
                            Text("Current tags (\(groupedTags.reduce(0) { $0 + $1.items.count }))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Normalize") {
                                tags = MetadataTagFormatter.normalizedCSV(from: tags)
                            }
                            .disabled(tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if groupedTags.isEmpty {
                            Text("No tags.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView(.vertical) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(groupedTags) { group in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(group.title)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 8) {
                                                ForEach(group.items, id: \.self) { item in
                                                    MetadataTagEditorChip(
                                                        text: item.display,
                                                        isLink: isOpenableSourceTag(item),
                                                        onTap: {
                                                            openSourceTag(item)
                                                        }
                                                    ) {
                                                        removeTag(item.rawToken)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .frame(maxHeight: 210)
                        }

                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run plugin on this archive")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Picker("Plugin", selection: $selectedPluginID) {
                                Text("Select plugin").tag(Optional<String>.none)
                                ForEach(pluginsVM.plugins, id: \.id) { p in
                                    Text(p.title).tag(Optional(p.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(isLoading || isDeleting || pluginRunning || pluginsVM.plugins.isEmpty)

                            Button("Refresh") {
                                Task { await loadPlugins() }
                            }
                            .disabled(isLoading || isDeleting || pluginRunning)
                        }

                        if let plugin = selectedPlugin {
                            if let d = plugin.description, !d.isEmpty {
                                Text(d)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            if !plugin.parameters.isEmpty {
                                DisclosureGroup(isExpanded: $showPluginSettings) {
                                    ScrollView(.vertical) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(plugin.parameters) { param in
                                                pluginOptionRow(param)
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 150)
                                    .padding(.top, 4)
                                } label: {
                                    Text("Plugin settings")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                        }

                        TextField(selectedPlugin?.oneshotArg ?? "Plugin URL/arg (optional)", text: $pluginArgText)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isLoading || isDeleting || pluginRunning)

                        HStack {
                            Button(pluginRunning ? "Queueing…" : "Queue Plugin") {
                                queuePluginForArchive()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoading || isDeleting || pluginRunning || selectedPluginID == nil)

                            Spacer()
                        }

                        if let pluginRunStatus {
                            Text(pluginRunStatus)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else if let status = pluginsVM.statusText {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 2)
            }
            .scrollIndicators(.visible)

            HStack {
                Button(isDeleting ? "Deleting…" : "Delete Archive…", role: .destructive) {
                    confirmDelete = true
                }
                .disabled(isLoading || isUpdatingCover || isDeleting || pluginRunning)

                Spacer()
                Button("Cancel") { dismiss() }
                Button(isLoading ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || isDeleting || pluginRunning)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .confirmationDialog(
            "Delete archive?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete \(arcid)", role: .destructive) {
                Task { await deleteArchive() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the archive from LANraragi.")
        }
        .task {
            await loadIfNeeded()
            await loadPlugins()
        }
        .onChange(of: tagQuery) { _, _ in
            Task { await refreshSuggestions() }
        }
        .onChange(of: summary) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            showSummaryEditor = !trimmed.isEmpty
        }
    }

    @ViewBuilder
    private func borderedTextEditor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            }
    }

    private func loadIfNeeded() async {
        if let m = initialMeta {
            apply(meta: m)
        } else {
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

        let settings = tagSuggestionSettings()
        await appModel.tagSuggestions.prewarm(profile: profile, settings: settings)
    }

    private func apply(meta: ArchiveMetadata) {
        let normalizedTitle = (meta.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTags = MetadataTagFormatter.normalizedCSV(from: meta.tags ?? "")
        let normalizedSummary = (meta.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        title = normalizedTitle
        tags = normalizedTags
        summary = normalizedSummary

        loadedTitle = normalizedTitle
        loadedTags = normalizedTags
        loadedSummary = normalizedSummary
        showSummaryEditor = !normalizedSummary.isEmpty

        pageCount = max(0, meta.pagecount ?? 0)
        coverPage = min(max(1, coverPage), max(1, pageCount))
        coverStatusText = nil
    }

    private func save() async {
        errorText = nil
        isLoading = true
        defer { isLoading = false }

        let editedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedTags = MetadataTagFormatter.normalizedCSV(from: tags)
        let editedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            // Preserve untouched fields from the latest metadata response so the API always receives
            // a full metadata payload (title/tags/summary), even when opened with partial initial data.
            let latest = try? await archives.metadata(profile: profile, arcid: arcid)
            let latestTitle = (latest?.title ?? loadedTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            let latestTags = MetadataTagFormatter.normalizedCSV(from: latest?.tags ?? loadedTags)
            let latestSummary = (latest?.summary ?? loadedSummary).trimmingCharacters(in: .whitespacesAndNewlines)

            let titleToSend = (editedTitle != loadedTitle) ? editedTitle : latestTitle
            let tagsToSend = (editedTags != loadedTags) ? editedTags : latestTags
            let summaryToSend = (editedSummary != loadedSummary) ? editedSummary : latestSummary

            let updated = try await archives.updateMetadata(
                profile: profile,
                arcid: arcid,
                title: titleToSend,
                tags: tagsToSend,
                summary: summaryToSend
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

        tags = MetadataTagFormatter.adding(t, to: tags)
        tagQuery = ""
        tagSuggestions = []
    }

    private func removeTag(_ rawToken: String) {
        tags = MetadataTagFormatter.removing(rawToken, from: tags)
    }

    private func isOpenableSourceTag(_ item: MetadataTagFormatter.Item) -> Bool {
        item.namespace.lowercased() == "source" && sourceURL(from: item.value) != nil
    }

    private func openSourceTag(_ item: MetadataTagFormatter.Item) {
        guard item.namespace.lowercased() == "source" else { return }
        guard let url = sourceURL(from: item.value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func sourceURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           let host = url.host,
           !host.isEmpty {
            return url
        }

        let candidate: String
        if trimmed.hasPrefix("//") {
            candidate = "https:" + trimmed
        } else {
            candidate = "https://" + trimmed
        }

        guard let url = URL(string: candidate),
              let host = url.host,
              host.contains(".") else {
            return nil
        }
        return url
    }

    private func setCoverFromPage() async {
        let boundedPage = min(max(1, coverPage), max(1, pageCount))
        guard pageCount > 0 else { return }

        coverStatusText = nil
        isUpdatingCover = true
        defer { isUpdatingCover = false }

        do {
            try await archives.updateThumbnail(profile: profile, arcid: arcid, page: boundedPage)
            await appModel.thumbnails.invalidate(profile: profile, arcid: arcid)

            coverStatusText = "Cover updated to page \(boundedPage)."
            appModel.activity.add(.init(kind: .action, title: "Updated archive cover", detail: "\(arcid) • page \(boundedPage)"))
        } catch {
            if Task.isCancelled { return }
            let short = ErrorPresenter.short(error)
            coverStatusText = "Failed: \(short)"
            appModel.activity.add(.init(kind: .error, title: "Cover update failed", detail: "\(arcid) • page \(boundedPage)\n\(error)"))
        }
    }

    private func deleteArchive() async {
        errorText = nil
        isDeleting = true
        defer { isDeleting = false }

        do {
            try await onDelete(arcid)
            dismiss()
        } catch {
            if Task.isCancelled { return }
            errorText = ErrorPresenter.short(error)
        }
    }

    private func tagSuggestionSettings() -> TagSuggestionStore.Settings {
        let minWeight = UserDefaults.standard.integer(forKey: "tags.minWeight")
        let ttlHours = max(1, UserDefaults.standard.integer(forKey: "tags.ttlHours"))
        return TagSuggestionStore.Settings(minWeight: minWeight, ttlSeconds: ttlHours * 60 * 60)
    }

    private func refreshSuggestions() async {
        let q = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            await MainActor.run { tagSuggestions = [] }
            return
        }

        let settings = tagSuggestionSettings()

        let sugg = await appModel.tagSuggestions.suggestions(profile: profile, settings: settings, prefix: q, limit: 20)
        await MainActor.run { tagSuggestions = sugg }
    }

    private func loadPlugins() async {
        await pluginsVM.load(profile: profile)
        if let selectedPluginID, pluginsVM.plugins.contains(where: { $0.id == selectedPluginID }) {
            return
        }
        selectedPluginID = pluginsVM.plugins.first?.id
    }

    private func queuePluginForArchive() {
        guard let pluginID = selectedPluginID else { return }
        pluginRunning = true
        pluginRunStatus = "Queueing plugin job…"

        Task {
            do {
                let job = try await pluginsVM.queue(profile: profile, pluginID: pluginID, arcid: arcid, arg: pluginArgText)
                pluginsVM.trackQueuedJob(profile: profile, pluginID: pluginID, arcid: arcid, jobID: job.job)
                await MainActor.run {
                    pluginRunning = false
                    pluginRunStatus = job.job > 0
                        ? "Queued job \(job.job)."
                        : "Plugin executed (server did not return a trackable job id)."
                }
                let detail = job.job > 0
                    ? "\(pluginID) • \(arcid) • job \(job.job)"
                    : "\(pluginID) • \(arcid) • executed (no job id returned)"
                appModel.activity.add(.init(kind: .action, title: "Plugin job queued", detail: detail))

                if job.job > 0 {
                    let state = await pluginsVM.waitForJobCompletion(profile: profile, jobID: job.job)
                    switch state {
                    case .finished:
                        await refreshMetadataAfterPlugin(status: "Plugin completed. Metadata refreshed.")
                    case .failed:
                        await MainActor.run {
                            pluginRunStatus = "Plugin job \(job.job) failed."
                        }
                    case .queued, .running, .unknown:
                        await MainActor.run {
                            pluginRunStatus = "Plugin job \(job.job) finished with unknown state."
                        }
                    }
                } else {
                    await refreshMetadataAfterPlugin(status: "Plugin completed. Metadata refreshed.")
                }
            } catch {
                await MainActor.run {
                    pluginRunning = false
                    pluginRunStatus = "Failed: \(ErrorPresenter.short(error))"
                }
                appModel.activity.add(.init(kind: .error, title: "Plugin queue failed", detail: "\(pluginID) • \(arcid)\n\(error)"))
            }
        }
    }

    private func refreshMetadataAfterPlugin(status: String) async {
        do {
            let updated = try await archives.metadata(profile: profile, arcid: arcid)
            await MainActor.run {
                apply(meta: updated)
                pluginRunStatus = status
            }
            appModel.activity.add(.init(kind: .action, title: "Plugin metadata refreshed", detail: arcid))
        } catch {
            await MainActor.run {
                pluginRunStatus = "Plugin finished, but refresh failed: \(ErrorPresenter.short(error))"
            }
            appModel.activity.add(.init(kind: .warning, title: "Plugin refresh failed", detail: "\(arcid)\n\(error)"))
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
                        .font(.caption2.weight(.semibold))
                }
                .toggleStyle(.switch)
                .disabled(true)
            } else {
                Text(title)
                    .font(.caption2.weight(.semibold))
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

private struct MetadataTagEditorChip: View {
    let text: String
    let isLink: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                onTap()
            } label: {
                Text(text)
                    .font(.callout)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(isLink ? .blue : .primary)
            }
            .buttonStyle(.plain)
            .disabled(!isLink)
            .help(isLink ? "Open source URL" : "")

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove tag")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }
}

private enum MetadataTagFormatter {
    struct Item: Hashable {
        let namespace: String
        let value: String
        let display: String
        let rawToken: String
    }

    struct Group: Identifiable, Hashable {
        let id: String
        let title: String
        let items: [Item]
    }

    private static let humanDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let dateOnlyParsers: [DateFormatter] = {
        func make(_ format: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = format
            return f
        }
        return [
            make("yyyy-MM-dd"),
            make("yyyy/MM/dd"),
        ]
    }()

    static func grouped(tags: String) -> [Group] {
        let items = sortedItems(from: tags)
        let grouped = Dictionary(grouping: items) { groupKey(namespace: $0.namespace) }
        let keys = grouped.keys.sorted(by: sortGroupKeys)

        return keys.map { key in
            let title = (key == "tag") ? "Tags" : key
            let values = grouped[key] ?? []
            return Group(id: key, title: title, items: values)
        }
    }

    static func normalizedCSV(from tags: String) -> String {
        sortedItems(from: tags).map(\.rawToken).joined(separator: ", ")
    }

    static func adding(_ rawToken: String, to tags: String) -> String {
        let candidate = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return normalizedCSV(from: tags) }
        return normalizedCSV(from: tags + (tags.isEmpty ? "" : ", ") + candidate)
    }

    static func removing(_ rawToken: String, from tags: String) -> String {
        let target = rawToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return normalizedCSV(from: tags) }

        let kept = sortedItems(from: tags)
            .filter { $0.rawToken.lowercased() != target }
            .map(\.rawToken)
        return kept.joined(separator: ", ")
    }

    private static func sortedItems(from tags: String) -> [Item] {
        let raw = tags
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen: Set<String> = []
        var out: [Item] = []
        out.reserveCapacity(raw.count)

        for tok in raw {
            guard let item = makeItem(from: tok) else { continue }
            if seen.insert(item.rawToken.lowercased()).inserted {
                out.append(item)
            }
        }

        out.sort { a, b in
            let aKey = groupKey(namespace: a.namespace)
            let bKey = groupKey(namespace: b.namespace)
            if aKey != bKey { return sortGroupKeys(aKey, bKey) }

            let byDisplay = a.display.localizedCaseInsensitiveCompare(b.display)
            if byDisplay != .orderedSame { return byDisplay == .orderedAscending }
            return a.rawToken.localizedCaseInsensitiveCompare(b.rawToken) == .orderedAscending
        }

        return out
    }

    private static func makeItem(from token: String) -> Item? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (namespace, value) = splitNamespace(trimmed)
        let canonicalToken = namespace.isEmpty ? value : "\(namespace):\(value)"
        guard !canonicalToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let display: String
        if isDateNamespace(namespace), let d = parseDateValue(value) {
            display = "\(namespace):\(humanDateFormatter.string(from: d))"
        } else {
            display = canonicalToken
        }

        return Item(namespace: namespace, value: value, display: display, rawToken: canonicalToken)
    }

    private static func groupKey(namespace: String) -> String {
        let key = namespace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? "tag" : key
    }

    private static func sortGroupKeys(_ a: String, _ b: String) -> Bool {
        if a == "tag", b != "tag" { return true }
        if a != "tag", b == "tag" { return false }
        return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }

    private static func splitNamespace(_ token: String) -> (String, String) {
        guard let idx = token.firstIndex(of: ":") else { return ("", token) }
        let ns = String(token[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(token[token.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (ns, value)
    }

    private static func isDateNamespace(_ namespace: String) -> Bool {
        let ns = namespace.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ns == "date_added" || ns == "dateadded" || ns == "date"
    }

    private static func parseDateValue(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "\"'"))

        if let rawNum = Int64(trimmed) {
            let seconds: TimeInterval
            if rawNum > 1_000_000_000_000 {
                seconds = TimeInterval(rawNum) / 1000.0
            } else {
                seconds = TimeInterval(rawNum)
            }
            return Date(timeIntervalSince1970: seconds)
        }

        for f in dateOnlyParsers {
            if let d = f.date(from: trimmed) {
                return d
            }
        }

        return nil
    }
}
