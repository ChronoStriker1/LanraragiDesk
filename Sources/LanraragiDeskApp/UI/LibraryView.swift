import Foundation
import AppKit
import SwiftUI
import LanraragiKit

struct LibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    let profile: Profile

    @StateObject private var vm = LibraryViewModel()
    @State private var tagSuggestions: [TagSuggestionStore.Suggestion] = []
    @State private var suggestionTask: Task<Void, Never>?
    @State private var editingMeta: EditorRoute?

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
            if vm.arcids.isEmpty {
                vm.refresh(profile: profile)
            }
            Task { await vm.loadCategories(profile: profile) }
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

                Picker("Sort", selection: $vm.sort) {
                    ForEach(LibraryViewModel.Sort.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .frame(width: 170)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Search…", text: $vm.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { vm.refresh(profile: profile) }
                        .onChange(of: vm.query) { _, _ in
                            queueSuggestionRefresh()
                        }

                    if !tagSuggestions.isEmpty {
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(tagSuggestions.prefix(12), id: \.value) { s in
                                    Button {
                                        applySuggestion(s.value)
                                    } label: {
                                        HStack(spacing: 10) {
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
                        .frame(maxHeight: 160)
                    }
                }

                Button("Search") {
                    vm.refresh(profile: profile)
                }

                Button("Clear") {
                    vm.query = ""
                    vm.refresh(profile: profile)
                }
                .disabled(vm.query.isEmpty)

                Spacer()
            }

            DisclosureGroup("Filters") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        Toggle("New only", isOn: $vm.newOnly)
                        Toggle("Untagged only", isOn: $vm.untaggedOnly)
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Picker("Category", selection: $vm.categoryID) {
                            Text("All categories").tag("")

                            let pinned = vm.categories.filter { $0.pinned }
                            let unpinned = vm.categories.filter { !$0.pinned }

                            if !pinned.isEmpty {
                                Divider()
                                ForEach(pinned, id: \.id) { c in
                                    Label(c.name, systemImage: "pin.fill").tag(c.id)
                                }
                            }

                            if !unpinned.isEmpty {
                                Divider()
                                ForEach(unpinned, id: \.id) { c in
                                    Text(c.name).tag(c.id)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 340, alignment: .leading)

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
                        LibraryCard(profile: profile, arcid: arcid)
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
            List {
                ForEach(vm.arcids, id: \.self) { arcid in
                    LibraryRow(profile: profile, arcid: arcid)
                        .environmentObject(appModel)
                        .contentShape(Rectangle())
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
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .debugFrameNumber(2)
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

    private func refreshSuggestions() async {
        let info = currentTokenInfo()
        let q = info.lookupPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let minChars = info.hasTagPrefix ? 1 : 2
        guard q.count >= minChars else {
            await MainActor.run { tagSuggestions = [] }
            return
        }

        let minWeight = UserDefaults.standard.integer(forKey: "tags.minWeight")
        let ttlHours = max(1, UserDefaults.standard.integer(forKey: "tags.ttlHours"))
        let settings = TagSuggestionStore.Settings(minWeight: minWeight, ttlSeconds: ttlHours * 60 * 60)

        let sugg = await appModel.tagSuggestions.suggestions(profile: profile, settings: settings, prefix: q, limit: 20)
        await MainActor.run { tagSuggestions = sugg }
    }

    private func applySuggestion(_ value: String) {
        let info = currentTokenInfo()
        let trimmedRaw = info.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            vm.query = value + " "
            tagSuggestions = []
            return
        }

        let preservedTagPrefix = info.hasTagPrefix ? "tag:" : ""
        let token = (info.isNegated ? "-" : "") + preservedTagPrefix + value

        if let range = info.range {
            let head = String(vm.query[..<range.lowerBound])
            vm.query = head + token + " "
        } else {
            vm.query = token + " "
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

    private func currentTokenInfo() -> TokenInfo {
        let q = vm.query
        if q.isEmpty {
            return TokenInfo(raw: "", range: nil, isNegated: false, hasTagPrefix: false, lookupPrefix: "")
        }

        let separators = CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ","))
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
}

private struct LibraryCard: View {
    @EnvironmentObject private var appModel: AppModel

    let profile: Profile
    let arcid: String

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
                    VStack(alignment: .leading, spacing: 6) {
                        if meta?.isnew == true {
                            CoverBadge(text: "NEW", background: .green.opacity(0.85))
                        }

                        Button {
                            appModel.selection.toggle(arcid)
                        } label: {
                            Image(systemName: appModel.selection.contains(arcid) ? "checkmark.circle.fill" : "circle")
                                .imageScale(.large)
                                .foregroundStyle(appModel.selection.contains(arcid) ? .green : .secondary)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Select for batch operations")
                    }
                    .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if let d = ArchiveMetaHelpers.dateAdded(meta) {
                        CoverBadge(text: Self.dateFormatter.string(from: d))
                            .padding(8)
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
                        tags: meta?.tags ?? ""
                    )
                    .onHover { hovering in
                        hoveringPopover = hovering
                        updatePopoverVisibility()
                    }
                }

            Text(title)
                .font(.callout)
                .lineLimit(2)
        }
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
            Button {
                appModel.selection.toggle(arcid)
            } label: {
                Image(systemName: appModel.selection.contains(arcid) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(appModel.selection.contains(arcid) ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Select for batch operations")

            CoverThumb(profile: profile, arcid: arcid, thumbnails: appModel.thumbnails, size: .init(width: 54, height: 72))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if meta?.isnew == true {
                        CoverBadge(text: "NEW", background: .green.opacity(0.85), font: .caption2.weight(.bold))
                            .padding(4)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let d = ArchiveMetaHelpers.dateAdded(meta) {
                        CoverBadge(text: Self.dateFormatter.string(from: d), font: .caption2.monospacedDigit().weight(.bold))
                            .padding(4)
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
                        tags: meta?.tags ?? ""
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
    var background: Color = .black.opacity(0.7)
    var foreground: Color = .white
    var font: Font = .caption.monospacedDigit().weight(.bold)

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foreground)
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
                    if !tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(tags)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No tags.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(width: 520, height: 340)
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
