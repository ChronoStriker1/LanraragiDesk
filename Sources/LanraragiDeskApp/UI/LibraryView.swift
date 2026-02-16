import Foundation
import AppKit
import SwiftUI
import LanraragiKit

struct LibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    let profile: Profile

    @StateObject private var vm = LibraryViewModel()
    @State private var queryDraft: String = ""
    @State private var tagSuggestions: [TagSuggestionStore.Suggestion] = []
    @State private var tagSuggestionStatusText: String?
    @State private var tagSuggestionsLoading: Bool = false
    @State private var suggestionTask: Task<Void, Never>?
    @State private var editingMeta: EditorRoute?
    @FocusState private var searchFocused: Bool

    // Used by list/table view to avoid refetching metadata per-cell.
    @State private var metaByArcid: [String: ArchiveMetadata] = [:]
    @State private var listSortOrder: [KeyPathComparator<LibraryListRow>] = [
        .init(\.dateAddedSortKey, order: .reverse)
    ]

    struct EditorRoute: Identifiable, Hashable {
        let arcid: String
        var id: String { arcid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let banner = vm.bannerText {
                Text(banner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let err = vm.errorText {
                Text("Error: \(err)")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            results
        }
        .sheet(item: $editingMeta) { route in
            ArchiveMetadataEditorView(
                profile: profile,
                arcid: route.arcid,
                initialMeta: nil,
                archives: appModel.archives,
                onSaved: { _ in }
            )
            .environmentObject(appModel)
        }
        .onAppear {
            if queryDraft.isEmpty {
                queryDraft = vm.query
            }
            if vm.arcids.isEmpty {
                vm.refresh(profile: profile)
            }
            Task { await vm.loadCategories(profile: profile) }
            Task { await prewarmTagSuggestions() }
        }
        .onChange(of: vm.sort) { _, _ in
            vm.refresh(profile: profile)
        }
        .onChange(of: vm.newOnly) { _, _ in
            vm.refresh(profile: profile)
        }
        .onChange(of: vm.untaggedOnly) { _, _ in
            vm.refresh(profile: profile)
        }
        .onChange(of: vm.categoryID) { _, _ in
            vm.refresh(profile: profile)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Library")
                    .font(.title2)
                    .bold()

                Spacer()

                Picker("", selection: $vm.layout) {
                    Text("Grid").tag(LibraryViewModel.Layout.grid)
                    Text("List").tag(LibraryViewModel.Layout.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                if vm.layout == .grid {
                    Picker("Sort", selection: $vm.sort) {
                        ForEach(LibraryViewModel.Sort.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .frame(width: 170)
                }
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        TextField("Search…", text: $queryDraft)
                            .textFieldStyle(.roundedBorder)
                            .focused($searchFocused)
                            .onSubmit { handleSearchSubmit() }
                            .onChange(of: queryDraft) { _, _ in
                                queueSuggestionRefresh()
                            }
                            .frame(maxWidth: .infinity)

                        Button("Search") { handleSearchSubmit() }

                        Button("Clear") {
                            queryDraft = ""
                            vm.query = ""
                            vm.refresh(profile: profile)
                        }
                        .disabled(queryDraft.isEmpty)
                    }

                    tagSuggestionList
                }
                .zIndex(10)
            }

            DisclosureGroup("Filters") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Toggle("New only", isOn: $vm.newOnly)
                        Toggle("Untagged only", isOn: $vm.untaggedOnly)
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        pinnedCategoryButtons

                        Menu {
                            Button("All categories") { vm.categoryID = "" }

                            let unpinned = vm.categories.filter { !$0.pinned }
                            if !unpinned.isEmpty {
                                Divider()
                            }

                            ForEach(unpinned, id: \.id) { c in
                                Button(c.name) { vm.categoryID = c.id }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                Text(unpinnedCategoryLabel)
                            }
                            .font(.callout)
                        }
                        .menuStyle(.borderlessButton)

                        if vm.isLoadingCategories {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Spacer()
                    }

                    if let s = vm.categoriesStatusText {
                        Text("Categories unavailable: \(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .debugFrameNumber(1)
    }

    private var tagSuggestionList: some View {
        let info = currentTokenInfo(queryDraft)
        let q = info.lookupPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let minChars = 1
        let eligible = q.count >= minChars

        // Always reserve space under the search field so suggestions are reliably visible.
        return GroupBox {
            if !eligible {
                Text("Start typing to see tag suggestions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else if tagSuggestionsLoading {
                Text("Loading suggestions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else if tagSuggestions.isEmpty {
                Text(tagSuggestionStatusText ?? "No suggestions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(tagSuggestions.prefix(24), id: \.value) { s in
                            Button {
                                applySuggestion(s.value)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(s.value)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Text("\(s.weight)")
                                        .font(.caption2.monospacedDigit())
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
                .scrollIndicators(.visible)
                .frame(maxHeight: 170)

                if let tagSuggestionStatusText, !tagSuggestionStatusText.isEmpty {
                    Text(tagSuggestionStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pinnedCategoryButtons: some View {
        let pinned = vm.categories.filter { $0.pinned }

        return FlowLayout(spacing: 8, lineSpacing: 8) {
            CategoryChip(title: "All", selected: vm.categoryID.isEmpty) {
                vm.categoryID = ""
            }
            ForEach(pinned, id: \.id) { c in
                CategoryChip(title: c.name, selected: vm.categoryID == c.id, pinned: true) {
                    vm.categoryID = c.id
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unpinnedCategoryLabel: String {
        guard !vm.categoryID.isEmpty else { return "More categories" }
        if let c = vm.categories.first(where: { $0.id == vm.categoryID }), !c.pinned {
            return c.name
        }
        return "More categories"
    }

    private func addTagToQuery(_ rawTag: String) {
        let t = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        // Insert the raw tag token (ex: "female:ahegao" or "vanilla") without adding "tag:".
        let token = t
        let needsComma = !queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(",")
        queryDraft = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            + (needsComma ? ", " : "")
            + token
            + ", "
    }

    private func handleSearchSubmit() {
        let normalized = normalizeLANraragiQuery(queryDraft)
        queryDraft = normalized
        vm.query = normalized
        vm.refresh(profile: profile)
    }

    @ViewBuilder
    private var results: some View {
        switch vm.layout {
        case .grid:
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(vm.arcids, id: \.self) { arcid in
                        LibraryCard(profile: profile, arcid: arcid, onSelectTag: addTagToQuery)
                            .environmentObject(appModel)
                            .contextMenu {
                                Button("Open Reader") {
                                    openWindow(value: ReaderRoute(profileID: profile.id, arcid: arcid))
                                }
                                Button("Edit Metadata…") {
                                    editingMeta = EditorRoute(arcid: arcid)
                                }
                                Divider()
                                Button("Copy Archive ID") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(arcid, forType: .string)
                                }
                            }
                            .onTapGesture {
                                openWindow(value: ReaderRoute(profileID: profile.id, arcid: arcid))
                            }
                            .onAppear {
                                if arcid == vm.arcids.last {
                                    Task { await vm.loadMore(profile: profile) }
                                }
                            }
                    }

                    if vm.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(20)
                            .gridCellColumns(2)
                    }
                }
                .padding(.vertical, 6)
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .debugFrameNumber(2)

        case .list:
            libraryTable
        }
    }

    private func queueSuggestionRefresh() {
        suggestionTask?.cancel()
        suggestionTask = Task {
            // Light debounce so fast typing doesn't spam filtering.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            await refreshSuggestions()
        }
    }

    private var listRows: [LibraryListRow] {
        vm.arcids.map { arcid in
            let meta = metaByArcid[arcid]
            return LibraryListRow(arcid: arcid, meta: meta)
        }
    }

    private var sortedListRows: [LibraryListRow] {
        listRows.sorted(using: listSortOrder)
    }

    private var libraryTable: some View {
        Table(sortedListRows, sortOrder: $listSortOrder) {
            TableColumn("Select") { row in
                Button {
                    appModel.selection.toggle(row.arcid)
                } label: {
                    Image(systemName: appModel.selection.contains(row.arcid) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(appModel.selection.contains(row.arcid) ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Select for batch operations")
            }
            .width(min: 54, ideal: 54, max: 54)

            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 10) {
                    CoverThumb(profile: profile, arcid: row.arcid, thumbnails: appModel.thumbnails, size: .init(width: 38, height: 52))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(row.title)
                        .font(.callout)
                        .lineLimit(1)
                }
                .task(id: row.arcid) {
                    if metaByArcid[row.arcid] != nil { return }
                    do {
                        let meta = try await appModel.archives.metadata(profile: profile, arcid: row.arcid)
                        await MainActor.run { metaByArcid[row.arcid] = meta }
                    } catch {
                        // Leave as-is; cover/title still show.
                    }
                }
                .onAppear {
                    if row.arcid == vm.arcids.last {
                        Task { await vm.loadMore(profile: profile) }
                    }
                }
                .onTapGesture(count: 2) {
                    openWindow(value: ReaderRoute(profileID: profile.id, arcid: row.arcid))
                }
                .contextMenu {
                    Button("Open Reader") {
                        openWindow(value: ReaderRoute(profileID: profile.id, arcid: row.arcid))
                    }
                    Button("Edit Metadata…") {
                        editingMeta = EditorRoute(arcid: row.arcid)
                    }
                    Divider()
                    Button("Copy Archive ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.arcid, forType: .string)
                    }
                }
            }

            TableColumn("New", value: \.isNewSortKey) { row in
                if row.isNew {
                    Text("NEW")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                } else {
                    Text("")
                }
            }
            .width(min: 52, ideal: 52, max: 70)

            TableColumn("Date", value: \.dateAddedSortKey) { row in
                Text(row.dateAddedText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 120, max: 160)

            TableColumn("Artist", value: \.artist) { row in
                Text(row.artist)
                    .font(.callout)
                    .foregroundStyle(row.artist.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Group", value: \.group) { row in
                Text(row.group)
                    .font(.callout)
                    .foregroundStyle(row.group.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Tags", value: \.tags) { row in
                Text(row.tags)
                    .font(.callout)
                    .foregroundStyle(row.tags.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 220, ideal: 380)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(.thinMaterial)
        .debugFrameNumber(2)
    }

    private func refreshSuggestions() async {
        await MainActor.run {
            tagSuggestionsLoading = true
            tagSuggestionStatusText = nil
        }
        let info = currentTokenInfo(queryDraft)
        let q = info.lookupPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let minChars = 1
        guard q.count >= minChars else {
            await MainActor.run { tagSuggestions = [] }
            await MainActor.run { tagSuggestionsLoading = false }
            return
        }

        let minWeight = UserDefaults.standard.integer(forKey: "tags.minWeight")
        let ttlHours = max(1, UserDefaults.standard.integer(forKey: "tags.ttlHours"))
        let settings = TagSuggestionStore.Settings(minWeight: minWeight, ttlSeconds: ttlHours * 60 * 60)

        let sugg = await appModel.tagSuggestions.suggestions(profile: profile, settings: settings, prefix: q, limit: 20)
        let err = await appModel.tagSuggestions.lastError(profile: profile)
        await MainActor.run {
            tagSuggestions = sugg
            tagSuggestionStatusText = err
            tagSuggestionsLoading = false
        }
    }

    private func applySuggestion(_ value: String) {
        let info = currentTokenInfo(queryDraft)
        let trimmedRaw = info.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            queryDraft = value + ", "
            tagSuggestions = []
            return
        }

        let preservedTagPrefix = info.hasTagPrefix ? "tag:" : ""
        let token = (info.isNegated ? "-" : "") + preservedTagPrefix + value

        if let range = info.range {
            let head = String(queryDraft[..<range.lowerBound])
            queryDraft = head + token + ", "
        } else {
            queryDraft = token + ", "
        }
        tagSuggestions = []
    }

    private struct TokenInfo {
        var raw: String
        var range: Range<String.Index>?
        var isNegated: Bool
        var hasTagPrefix: Bool
        var lookupPrefix: String
    }

    private func currentTokenInfo(_ query: String) -> TokenInfo {
        let q = query
        if q.isEmpty {
            return TokenInfo(raw: "", range: nil, isNegated: false, hasTagPrefix: false, lookupPrefix: "")
        }

        let separators = CharacterSet(charactersIn: ",;\n\r")
        if let r = q.rangeOfCharacter(from: separators, options: .backwards) {
            let token = String(q[r.upperBound...])
            return parseToken(token, range: r.upperBound..<q.endIndex)
        }
        return parseToken(q, range: nil)
    }

    private func parseToken(_ token: String, range: Range<String.Index>?) -> TokenInfo {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var raw = trimmed

        var isNegated = false
        if raw.hasPrefix("-") {
            isNegated = true
            raw.removeFirst()
        }

        var hasTagPrefix = false
        if raw.lowercased().hasPrefix("tag:") {
            hasTagPrefix = true
            raw.removeFirst(4)
        }

        return TokenInfo(
            raw: trimmed,
            range: range,
            isNegated: isNegated,
            hasTagPrefix: hasTagPrefix,
            lookupPrefix: raw
        )
    }

    private func prewarmTagSuggestions() async {
        let minWeight = UserDefaults.standard.integer(forKey: "tags.minWeight")
        let ttlHours = max(1, UserDefaults.standard.integer(forKey: "tags.ttlHours"))
        let settings = TagSuggestionStore.Settings(minWeight: minWeight, ttlSeconds: ttlHours * 60 * 60)
        await appModel.tagSuggestions.prewarm(profile: profile, settings: settings)
    }

    // LANraragi treats commas as token delimiters. Spaces are valid inside a token.
    // We normalize only explicit separators (; and newlines) to commas and trim comma spacing.
    private func normalizeLANraragiQuery(_ input: String) -> String {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        var buf = ""
        var inQuotes = false
        var parts: [String] = []
        parts.reserveCapacity(8)

        func flushBuf() {
            let piece = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            buf = ""
            guard !piece.isEmpty else { return }
            parts.append(piece)
        }

        for ch in s {
            if ch == "\"" {
                inQuotes.toggle()
                buf.append(ch)
                continue
            }
            if (ch == "," || ch == ";" || ch.isNewline), !inQuotes {
                flushBuf()
                continue
            }
            buf.append(ch)
        }
        flushBuf()

        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

private struct LibraryListRow: Identifiable, Hashable {
    let arcid: String

    let isNew: Bool
    let dateAdded: Date?
    let title: String
    let artist: String
    let group: String
    let tags: String

    var id: String { arcid }

    // Sort keys must be non-optional.
    var isNewSortKey: Int { isNew ? 1 : 0 }
    var dateAddedSortKey: Double { dateAdded?.timeIntervalSince1970 ?? 0 }

    var dateAddedText: String {
        guard let dateAdded else { return "" }
        return Self.dateFormatter.string(from: dateAdded)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    init(arcid: String, meta: ArchiveMetadata?) {
        self.arcid = arcid

        let t = meta?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = t.isEmpty ? "Untitled" : t
        self.tags = (meta?.tags ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        self.isNew = meta?.isnew ?? false
        self.dateAdded = ArchiveMetaHelpers.dateAdded(meta)

        self.artist = ArchiveMetaHelpers.artists(meta).joined(separator: ", ")
        self.group = ArchiveMetaHelpers.groups(meta).joined(separator: ", ")
    }
}

private struct LibraryCard: View {
    @EnvironmentObject private var appModel: AppModel

    let profile: Profile
    let arcid: String
    let onSelectTag: (String) -> Void

    @State private var meta: ArchiveMetadata?
    @State private var title: String = "Loading…"
    @State private var showDetails: Bool = false
    @State private var hoveringCover: Bool = false
    @State private var hoveringPopover: Bool = false
    @State private var popoverCloseTask: Task<Void, Never>?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverThumb(profile: profile, arcid: arcid, thumbnails: appModel.thumbnails, size: .init(width: 160, height: 210))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        if meta?.isnew == true {
                            CoverBadge(text: "NEW", background: .green.opacity(0.55))
                        }

                        // Always positioned top-left; on hover it overlays other badges (ex: NEW).
                        if hoveringCover {
                            Button {
                                appModel.selection.toggle(arcid)
                            } label: {
                                Image(systemName: appModel.selection.contains(arcid) ? "checkmark.circle.fill" : "circle")
                                    .imageScale(.large)
                                    .foregroundStyle(appModel.selection.contains(arcid) ? .green : .white)
                                    .padding(8)
                                    .background(.black.opacity(0.22))
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                            }
                            .buttonStyle(.plain)
                            .help("Select for batch operations")
                            .zIndex(200)
                        }
                    }
                    .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    ZStack(alignment: .topTrailing) {
                        if let d = ArchiveMetaHelpers.dateAdded(meta) {
                            CoverBadge(text: Self.dateFormatter.string(from: d))
                                .padding(8)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if let pages = meta?.pagecount, pages > 0 {
                        HStack {
                            Spacer(minLength: 0)
                            CoverBadge(text: "\(pages) pages")
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                    }
                }
                .onHover { hovering in
                    hoveringCover = hovering
                    updatePopoverVisibility()
                }
                .popover(isPresented: $showDetails) {
                    ArchiveHoverDetailsView(
                        title: meta?.title ?? title,
                        summary: meta?.summary ?? "",
                        tags: meta?.tags ?? "",
                        onSelectTag: { rawTag in
                            onSelectTag(rawTag)
                            showDetails = false
                        }
                    )
                    .onHover { hovering in
                        hoveringPopover = hovering
                        updatePopoverVisibility()
                    }
                }

            Text(title)
                .font(.callout)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            let artists = ArchiveMetaHelpers.artists(meta)
            if !artists.isEmpty {
                Text("Artist: " + artists.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let groups = ArchiveMetaHelpers.groups(meta)
            if !groups.isEmpty {
                Text("Group: " + groups.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 182, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .task(id: arcid) {
            do {
                let meta = try await appModel.archives.metadata(profile: profile, arcid: arcid)
                let t = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                title = t.isEmpty ? "Untitled" : t
                self.meta = meta
            } catch {
                title = "Untitled"
                self.meta = nil
            }
        }
    }

    private func updatePopoverVisibility() {
        popoverCloseTask?.cancel()

        if hoveringCover || hoveringPopover {
            showDetails = true
            return
        }

        // Give the cursor time to move from the cover to the popover without it collapsing immediately.
        popoverCloseTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                if !(hoveringCover || hoveringPopover) {
                    showDetails = false
                }
            }
        }
    }
}

private struct LibraryRow: View {
    @EnvironmentObject private var appModel: AppModel

    let profile: Profile
    let arcid: String
    let onSelectTag: (String) -> Void

    @State private var meta: ArchiveMetadata?
    @State private var title: String = "Loading…"
    @State private var subtitle: String = ""
    @State private var showDetails: Bool = false
    @State private var hoveringCover: Bool = false
    @State private var hoveringPopover: Bool = false
    @State private var popoverCloseTask: Task<Void, Never>?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            CoverThumb(profile: profile, arcid: arcid, thumbnails: appModel.thumbnails, size: .init(width: 54, height: 72))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        if meta?.isnew == true {
                            CoverBadge(text: "NEW", background: .green.opacity(0.55), font: .caption2.weight(.bold))
                        }

                        if hoveringCover {
                            Button {
                                appModel.selection.toggle(arcid)
                            } label: {
                                Image(systemName: appModel.selection.contains(arcid) ? "checkmark.circle.fill" : "circle")
                                    .imageScale(.medium)
                                    .foregroundStyle(appModel.selection.contains(arcid) ? .green : .white)
                                    .padding(6)
                                    .background(.black.opacity(0.22))
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.35), radius: 1, x: 0, y: 1)
                            }
                            .buttonStyle(.plain)
                            .help("Select for batch operations")
                            .zIndex(200)
                        }
                    }
                    .padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    ZStack(alignment: .topTrailing) {
                        if let d = ArchiveMetaHelpers.dateAdded(meta) {
                            CoverBadge(text: Self.dateFormatter.string(from: d), font: .caption2.monospacedDigit().weight(.bold))
                                .padding(4)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if let pages = meta?.pagecount, pages > 0 {
                        CoverBadge(text: "\(pages)", font: .caption2.monospacedDigit().weight(.bold))
                            .padding(4)
                    }
                }
                .onHover { hovering in
                    hoveringCover = hovering
                    updatePopoverVisibility()
                }
                .popover(isPresented: $showDetails) {
                    ArchiveHoverDetailsView(
                        title: meta?.title ?? title,
                        summary: meta?.summary ?? "",
                        tags: meta?.tags ?? "",
                        onSelectTag: { rawTag in
                            onSelectTag(rawTag)
                            showDetails = false
                        }
                    )
                    .onHover { hovering in
                        hoveringPopover = hovering
                        updatePopoverVisibility()
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                if let line = ArchiveMetaHelpers.artistGroupLine(meta), !line.isEmpty {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .task(id: arcid) {
            do {
                let meta = try await appModel.archives.metadata(profile: profile, arcid: arcid)
                let t = meta.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                title = t.isEmpty ? "Untitled" : t
                let ext = meta.fileExtension?.uppercased() ?? ""
                let pages = meta.pagecount ?? 0
                subtitle = [pages > 0 ? "\(pages) pages" : nil, ext.isEmpty ? nil : ext].compactMap { $0 }.joined(separator: " • ")
                self.meta = meta
            } catch {
                title = "Untitled"
                subtitle = ""
                self.meta = nil
            }
        }
    }

    private func updatePopoverVisibility() {
        popoverCloseTask?.cancel()

        if hoveringCover || hoveringPopover {
            showDetails = true
            return
        }

        popoverCloseTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                if !(hoveringCover || hoveringPopover) {
                    showDetails = false
                }
            }
        }
    }
}

private struct CoverBadge: View {
    let text: String
    var background: Color = .black.opacity(0.55)
    var foreground: Color = .white
    var font: Font = .caption.monospacedDigit().weight(.bold)

    var body: some View {
        ZStack {
            // Faux-stroke for readability on busy thumbnails.
            Group {
                Text(text).offset(x: -1, y: 0)
                Text(text).offset(x: 1, y: 0)
                Text(text).offset(x: 0, y: -1)
                Text(text).offset(x: 0, y: 1)
            }
            .font(font)
            .foregroundStyle(.black.opacity(0.9))

            Text(text)
                .font(font)
                .foregroundStyle(foreground)
        }
        .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .allowsHitTesting(false)
    }
}

private struct ArchiveHoverDetailsView: View {
    let title: String
    let summary: String
    let tags: String
    let onSelectTag: (String) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.headline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No summary.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Tags")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TagGroupsView(tags: tags, onSelectTag: onSelectTag)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .scrollIndicators(.visible)
        .frame(width: 520, height: 340)
    }
}

private struct TagGroupsView: View {
    let tags: String
    let onSelectTag: (String) -> Void

    private struct TagItem: Hashable {
        var namespace: String
        var value: String
        var display: String
        var rawToken: String
    }

    private static let humanDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var items: [TagItem] {
        let raw = tags
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !raw.isEmpty else { return [] }

        return raw.map { tok in
            let (ns, v) = TagParser.splitNamespace(tok)
            let display: String
            if TagParser.isDateNamespace(ns), let d = TagParser.parseDateValue(v) {
                display = "\(ns):\(Self.humanDateFormatter.string(from: d))"
            } else {
                display = tok
            }
            return TagItem(namespace: ns, value: v, display: display, rawToken: tok)
        }
    }

    private var groups: [(String, [TagItem])] {
        let grouped = Dictionary(grouping: items) { $0.namespace.isEmpty ? "tag" : $0.namespace.lowercased() }
        let keys = grouped.keys.sorted { a, b in
            // Show un-namespaced tags first, then alphabetical.
            if a == "tag", b != "tag" { return true }
            if a != "tag", b == "tag" { return false }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return keys.map { k in
            let values = (grouped[k] ?? []).sorted { a, b in
                a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
            }
            return (k, values)
        }
    }

    var body: some View {
        if items.isEmpty {
            Text("No tags.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.0) { ns, items in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ns == "tag" ? "Tags" : ns)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(items, id: \.self) { t in
                                    TagChip(text: t.display) {
                                        onSelectTag(t.rawToken)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: 190)
        }
    }
}

private struct TagChip: View {
    let text: String
    let onClick: () -> Void

    var body: some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.leading)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                onClick()
            }
            .help("Click to add to Library search")
    }
}

private struct CategoryChip: View {
    let title: String
    let selected: Bool
    var pinned: Bool = false
    let onClick: () -> Void

    var body: some View {
        let bg: AnyShapeStyle = selected
            ? AnyShapeStyle(Color.accentColor.opacity(0.25))
            : AnyShapeStyle(.quaternary.opacity(0.35))

        Button {
            onClick()
        } label: {
            HStack(spacing: 6) {
                if pinned {
                    Image(systemName: "pin.fill")
                        .imageScale(.small)
                }
                Text(title)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(bg)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor).opacity(0.45),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

private enum TagParser {
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

    static func splitNamespace(_ tok: String) -> (String, String) {
        guard let idx = tok.firstIndex(of: ":") else { return ("", tok) }
        let ns = String(tok[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let v = String(tok[tok.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (ns, v)
    }

    static func isDateNamespace(_ ns: String) -> Bool {
        let n = ns.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n == "date_added" || n == "dateadded" || n == "date"
    }

    static func parseDateValue(_ v: String) -> Date? {
        let value = v.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "\"'"))

        if let rawNum = Int64(value) {
            let seconds: TimeInterval
            if rawNum > 1_000_000_000_000 {
                seconds = TimeInterval(rawNum) / 1000.0
            } else {
                seconds = TimeInterval(rawNum)
            }
            return Date(timeIntervalSince1970: seconds)
        }

        for f in dateOnlyParsers {
            if let d = f.date(from: value) {
                return d
            }
        }

        return nil
    }
}

private enum ArchiveMetaHelpers {
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

    static func dateAdded(_ meta: ArchiveMetadata?) -> Date? {
        guard let meta else { return nil }
        if let d = meta.dateAdded { return d }
        guard let tags = meta.tags else { return nil }
        return parseDateAddedTag(tags)
    }

    static func artists(_ meta: ArchiveMetadata?) -> [String] {
        guard let tags = meta?.tags else { return [] }
        return values(in: tags, namespace: "artist")
    }

    static func groups(_ meta: ArchiveMetadata?) -> [String] {
        guard let tags = meta?.tags else { return [] }
        return values(in: tags, namespace: "group")
    }

    static func artistGroupLine(_ meta: ArchiveMetadata?) -> String? {
        guard let tags = meta?.tags else { return nil }
        let artists = values(in: tags, namespace: "artist")
        let groups = values(in: tags, namespace: "group")

        var parts: [String] = []
        if !artists.isEmpty {
            parts.append("Artist: " + artists.joined(separator: ", "))
        }
        if !groups.isEmpty {
            parts.append("Group: " + groups.joined(separator: ", "))
        }
        return parts.joined(separator: "  •  ")
    }

    private static func values(in tags: String, namespace: String) -> [String] {
        let ns = namespace.lowercased()
        var out: [String] = []
        out.reserveCapacity(2)

        for raw in tags.split(separator: ",") {
            let tok = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idx = tok.firstIndex(of: ":") else { continue }
            let lhs = tok[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard lhs == ns else { continue }
            let rhs = tok[tok.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !rhs.isEmpty {
                out.append(rhs)
            }
        }

        // Keep order stable but de-dupe.
        var seen: Set<String> = []
        var uniq: [String] = []
        uniq.reserveCapacity(out.count)
        for v in out {
            if seen.insert(v.lowercased()).inserted {
                uniq.append(v)
            }
        }
        return uniq
    }

    private static func parseDateAddedTag(_ tags: String) -> Date? {
        for raw in tags.split(separator: ",") {
            let tok = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = tok.lowercased()

            let prefix: String
            if lower.hasPrefix("date_added:") {
                prefix = "date_added:"
            } else if lower.hasPrefix("dateadded:") {
                prefix = "dateadded:"
            } else {
                continue
            }

            let value = tok.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .init(charactersIn: "\"'"))

            if let rawNum = Int64(value) {
                let seconds: TimeInterval
                if rawNum > 1_000_000_000_000 {
                    seconds = TimeInterval(rawNum) / 1000.0
                } else {
                    seconds = TimeInterval(rawNum)
                }
                return Date(timeIntervalSince1970: seconds)
            }

            for f in dateOnlyParsers {
                if let d = f.date(from: value) {
                    return d
                }
            }
        }

        return nil
    }
}
