import AppKit
import ImageIO
import SwiftUI
import LanraragiKit

private enum ReviewLayout {
    static let pairCoverSize = CGSize(width: 112, height: 144)
    static let pairListWidth: CGFloat = 112 * 2
    // Must be >= one page preview tile height (tileHeight is capped at 240).
    static let minPagesViewportHeight: CGFloat = 260
    static let topBarSpacingToPages: CGFloat = 8
}

struct PairReviewView: View {
    let profile: Profile
    let result: DuplicateScanResult
    let thumbnails: ThumbnailLoader
    let archives: ArchiveLoader

    let markNotDuplicate: (DuplicateScanResult.Pair) -> Void
    let deleteArchive: (String) async throws -> Void

    @AppStorage("review.hoverPagePreview") private var hoverPagePreview: Bool = true

    @State private var selection: DuplicateScanResult.Pair?
    @State private var query: String = ""
    @State private var matchFilter: MatchFilter = .both
    @State private var errorText: String?

    private enum MatchFilter: String, CaseIterable, Hashable {
        case both
        case exact
        case similar

        var title: String {
            switch self {
            case .both: return "Both"
            case .exact: return "Exact"
            case .similar: return "Similar"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }
            header

            HSplitView {
                pairList
                    // Exactly two covers wide, per user request.
                    .frame(width: ReviewLayout.pairListWidth)

                pairDetail
                    .frame(minWidth: 520)
            }
        }
        .onChange(of: query) { _, _ in selection = nil }
        .onChange(of: matchFilter) { _, _ in selection = nil }
        .onChange(of: filteredPairs) { _, new in
            // If the underlying result changes (delete / not-a-match), clear invalid selections.
            if let sel = selection, !new.contains(sel) {
                selection = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Matches")
                    .font(.title2)
                    .bold()
                Text("Pairs: \(filteredPairs.count)  •  Archives scanned: \(result.stats.archives)  •  Time: \(String(format: "%.1fs", result.stats.durationSeconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Picker("Match filter", selection: $matchFilter) {
                    ForEach(MatchFilter.allCases, id: \.self) { f in
                        Text(f.title).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                TextField("Search ID…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)

                Menu {
                    Toggle("Hover page preview", isOn: $hoverPagePreview)
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .debugFrameNumber(1)
    }

    private var filteredPairs: [DuplicateScanResult.Pair] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.pairs.filter { p in
            switch matchFilter {
            case .both:
                break
            case .exact:
                if p.reason != .exactCover { return false }
            case .similar:
                if p.reason != .similarCover { return false }
            }
            if q.isEmpty { return true }
            return p.arcidA.localizedCaseInsensitiveContains(q) || p.arcidB.localizedCaseInsensitiveContains(q)
        }
    }

    private var exactPairs: [DuplicateScanResult.Pair] {
        filteredPairs.filter { $0.reason == .exactCover }
    }

    private var similarPairs: [DuplicateScanResult.Pair] {
        filteredPairs.filter { $0.reason == .similarCover }.sorted { $0.score < $1.score }
    }

    private var pairList: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 6) {
                if matchFilter == .both || matchFilter == .exact {
                    sectionHeader("Exact")
                    ForEach(exactPairs, id: \.self) { p in
                        pairRow(p)
                    }
                }

                if matchFilter == .both || matchFilter == .similar {
                    sectionHeader("Similar")
                        .padding(.top, 4)
                    ForEach(similarPairs, id: \.self) { p in
                        pairRow(p)
                    }
                }
            }
            // SwiftUI ScrollView content can size to its children; enforce full-width so covers are flush
            // to the left and right edges (no centering gap).
            .frame(width: ReviewLayout.pairListWidth, alignment: .leading)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.visible)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .debugFrameNumber(2)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.45))
                .clipShape(Capsule())
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func pairRow(_ p: DuplicateScanResult.Pair) -> some View {
        PairRowView(
            profile: profile,
            pair: p,
            thumbnails: thumbnails,
            markNotDuplicate: { pair in
                let next = nextPair(after: pair)
                markNotDuplicate(pair)
                selection = next
            }
        )
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selection == p ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selection == p ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = p }
    }

    private func orderedPairsForNavigation() -> [DuplicateScanResult.Pair] {
        var out: [DuplicateScanResult.Pair] = []
        if matchFilter == .both || matchFilter == .exact { out.append(contentsOf: exactPairs) }
        if matchFilter == .both || matchFilter == .similar { out.append(contentsOf: similarPairs) }
        return out
    }

    private func nextPair(after pair: DuplicateScanResult.Pair) -> DuplicateScanResult.Pair? {
        let ordered = orderedPairsForNavigation()
        guard let idx = ordered.firstIndex(of: pair) else { return nil }
        let nextIdx = ordered.index(after: idx)
        return nextIdx < ordered.endIndex ? ordered[nextIdx] : nil
    }

    private var pairDetail: some View {
        let ordered = orderedPairsForNavigation()
        if ordered.isEmpty {
            return AnyView(
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Try enabling more match types or clearing the filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .debugFrameNumber(3)
            )
        }

        guard let selection else {
            return AnyView(
                ContentUnavailableView(
                    "Select a pair",
                    systemImage: "rectangle.and.hand.point.up.left",
                    description: Text("Pick a match on the left to compare side-by-side.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .debugFrameNumber(3)
            )
        }

        guard ordered.contains(selection) else {
            return AnyView(
                ContentUnavailableView(
                    "Select a pair",
                    systemImage: "rectangle.and.hand.point.up.left",
                    description: Text("Pick a match on the left to compare side-by-side.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .debugFrameNumber(3)
            )
        }

        let p = selection
        let next = nextPair(after: p)
        return AnyView(
            PairCompareView(
                profile: profile,
                pair: p,
                thumbnails: thumbnails,
                archives: archives,
                markNotDuplicate: markNotDuplicate,
                deleteArchive: deleteArchive,
                reportError: { msg in
                    errorText = msg
                },
                goNext: {
                    self.selection = next
                }
            )
            .debugFrameNumber(3)
        )
    }
}

private struct PairRowView: View {
    let profile: Profile
    let pair: DuplicateScanResult.Pair
    let thumbnails: ThumbnailLoader
    let markNotDuplicate: (DuplicateScanResult.Pair) -> Void

    var body: some View {
        HStack(spacing: 0) {
            CoverThumb(
                profile: profile,
                arcid: pair.arcidA,
                thumbnails: thumbnails,
                size: ReviewLayout.pairCoverSize,
                contentInset: 0
            )
            CoverThumb(
                profile: profile,
                arcid: pair.arcidB,
                thumbnails: thumbnails,
                size: ReviewLayout.pairCoverSize,
                contentInset: 0
            )
        }
        .frame(width: ReviewLayout.pairListWidth, alignment: .leading)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(reasonColor.opacity(0.9))
                .frame(width: 4)
        }
        .contextMenu {
            Button("Not a match") { markNotDuplicate(pair) }
        }
    }

    private var reasonColor: Color {
        switch pair.reason {
        case .exactCover:
            return .green
        case .similarCover:
            return .orange
        }
    }
}

private struct PairCompareView: View {
    let profile: Profile
    let pair: DuplicateScanResult.Pair
    let thumbnails: ThumbnailLoader
    let archives: ArchiveLoader
    let markNotDuplicate: (DuplicateScanResult.Pair) -> Void
    let deleteArchive: (String) async throws -> Void
    let reportError: (String) -> Void
    let goNext: () -> Void

    @State private var confirmDeleteArcid: String?
    @State private var editingArcid: String?
    @State private var metaA: ArchiveMetadata?
    @State private var metaB: ArchiveMetadata?
    @State private var pagesScrollMinY: CGFloat = 0
    @State private var isDetailsCollapsed: Bool = false
    @State private var panelScrollY: CGFloat = 0
    @State private var panelScrollActiveID: Int? = nil
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.height
            // Pre-collapse: allocate most height to the archive panels (5/8), while reserving a
            // minimum visible pages viewport (7).
            let maxTopFromMinPages = max(180, available - ReviewLayout.minPagesViewportHeight - ReviewLayout.topBarSpacingToPages)
            let expandedTop = max(240, min(maxTopFromMinPages, available * 0.82))
            // Collapsed state keeps header + metadata; Tags collapse away.
            let collapsedTop = max(200, min(expandedTop, available * 0.34))
            let topHeight = isDetailsCollapsed ? collapsedTop : expandedTop

            VStack(alignment: .leading, spacing: 8) {
                topBar
                    // Keep 5 and 8 mirrored in height; overflow scrolls internally.
                    .frame(height: topHeight, alignment: .top)
                    .animation(.snappy(duration: 0.2), value: isDetailsCollapsed)

                SyncedPagesGridView(
                    profile: profile,
                    arcidA: pair.arcidA,
                    arcidB: pair.arcidB,
                    archives: archives,
                    scrollMinY: $pagesScrollMinY
                )
                .debugFrameNumber(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: ReviewLayout.minPagesViewportHeight)
                .layoutPriority(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .debugFrameNumber(4)
        .confirmationDialog(
            "Delete Archive?",
            isPresented: Binding(
                get: { confirmDeleteArcid != nil },
                set: { if !$0 { confirmDeleteArcid = nil } }
            )
        ) {
            if let arcid = confirmDeleteArcid {
                Button("Delete \(arcid)", role: .destructive) {
                    Task {
                        do {
                            try await deleteArchive(arcid)
                            await MainActor.run {
                                // Move forward after destructive actions; the deleted archive is removed from the results list.
                                goNext()
                            }
                        } catch {
                            reportError("Delete failed: \(error)")
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the archive from LANraragi. This cannot be undone.")
        }
        .sheet(item: Binding(
            get: { editingArcid.map(ArcidBox.init) },
            set: { editingArcid = $0?.arcid }
        )) { box in
            let arcid = box.arcid
            ArchiveMetadataEditorView(
                profile: profile,
                arcid: arcid,
                initialMeta: arcid == pair.arcidA ? metaA : (arcid == pair.arcidB ? metaB : nil),
                archives: archives,
                onSaved: { updated in
                    if updated.arcid == pair.arcidA { metaA = updated }
                    if updated.arcid == pair.arcidB { metaB = updated }
                },
                onDelete: { deletingArcid in
                    try await deleteArchive(deletingArcid)
                    await MainActor.run {
                        goNext()
                    }
                }
            )
        }
        .task(id: "\(pair.arcidA)|\(pair.arcidB)") {
            isDetailsCollapsed = false
            metaA = nil
            metaB = nil
            do {
                async let a = archives.metadata(profile: profile, arcid: pair.arcidA)
                async let b = archives.metadata(profile: profile, arcid: pair.arcidB)
                metaA = try await a
                metaB = try await b
            } catch {
                // Ignore; the compare UI still works with IDs only.
            }
        }
        .onChange(of: pagesScrollMinY) { _, v in
            // Hysteresis avoids flicker around the top of the pages grid.
            let collapseAt: CGFloat = -18
            let expandAt: CGFloat = -4
            if !isDetailsCollapsed, v < collapseAt {
                isDetailsCollapsed = true
            } else if isDetailsCollapsed, v > expandAt {
                isDetailsCollapsed = false
            }
        }
    }

    private var topBar: some View {
        let tagRows = TagCompareGrouper.rows(tagsA: metaA?.tags, tagsB: metaB?.tags, maxGroups: 8, maxTagsPerGroup: 18)

        // Top align panels so a taller tag list on one side doesn't vertically-center the other side,
        // which creates a changing gap above the shorter side.
        return HStack(alignment: .top, spacing: 0) {
            ArchiveComparePanel(
                profile: profile,
                arcid: pair.arcidA,
                meta: metaA,
                other: metaB,
                tagRows: tagRows,
                showingLeft: true,
                thumbnails: thumbnails,
                collapsed: isDetailsCollapsed,
                scrollY: $panelScrollY,
                scrollActiveID: $panelScrollActiveID,
                scrollID: 0,
                onRead: {
                    openReader(pair.arcidA)
                },
                onEdit: {
                    editingArcid = pair.arcidA
                },
                onNotMatch: {
                    markNotDuplicate(pair)
                    goNext()
                },
                onDelete: { confirmDeleteArcid = pair.arcidA }
            )
            .id(pair.arcidA)
            .frame(maxWidth: .infinity, alignment: .leading)
            .debugFrameNumber(5)

            ZStack(alignment: .top) {
                Divider()
                    .padding(.vertical, 10)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 28)
            .debugFrameNumber(6)

            ArchiveComparePanel(
                profile: profile,
                arcid: pair.arcidB,
                meta: metaB,
                other: metaA,
                tagRows: tagRows,
                showingLeft: false,
                thumbnails: thumbnails,
                collapsed: isDetailsCollapsed,
                scrollY: $panelScrollY,
                scrollActiveID: $panelScrollActiveID,
                scrollID: 1,
                onRead: {
                    openReader(pair.arcidB)
                },
                onEdit: {
                    editingArcid = pair.arcidB
                },
                onNotMatch: {
                    markNotDuplicate(pair)
                    goNext()
                },
                onDelete: { confirmDeleteArcid = pair.arcidB }
            )
            .id(pair.arcidB)
            .frame(maxWidth: .infinity, alignment: .leading)
            .debugFrameNumber(8)
        }
    }

    private func openReader(_ arcid: String) {
        appModel.setActiveReader(profileID: profile.id, arcid: arcid)
        openWindow(id: "reader")
    }

    private struct ArcidBox: Identifiable {
        let arcid: String
        var id: String { arcid }
    }
}

private struct ArchiveComparePanel: View {
    let profile: Profile
    let arcid: String
    let meta: ArchiveMetadata?
    let other: ArchiveMetadata?
    let tagRows: [TagCompareGrouper.Row]
    let showingLeft: Bool
    let thumbnails: ThumbnailLoader
    let collapsed: Bool
    @Binding var scrollY: CGFloat
    @Binding var scrollActiveID: Int?
    let scrollID: Int
    let onRead: () -> Void
    let onEdit: () -> Void
    let onNotMatch: () -> Void
    let onDelete: () -> Void

    var body: some View {
        // "collapsed" = collapse Tags away (everything from the Tags section down).
        VStack(alignment: .leading, spacing: 10) {
            ArchiveSideHeader(
                profile: profile,
                arcid: arcid,
                meta: meta,
                thumbnails: thumbnails,
                onRead: onRead,
                onEdit: onEdit,
                onNotMatch: onNotMatch,
                onDelete: onDelete
            )

            ScrollView(.vertical) {
                SyncedScrollBridge(
                    id: scrollID,
                    offsetY: $scrollY,
                    activeID: $scrollActiveID
                )
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)

                ArchiveSideDetails(meta: meta, other: other)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !collapsed {
                    ArchiveSideTags(tagRows: tagRows, showingLeft: showingLeft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                        .padding(.trailing, 4)
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(collapsed ? 8 : 12)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct TagGroupsView: View {
    let tags: String?

    var body: some View {
        let groups = TagGrouper.grouped(tags: tags)
        if groups.isEmpty {
            return AnyView(EmptyView())
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(g.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(g.displayTags, id: \.self) { t in
                                Text(t)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(.quaternary.opacity(0.55))
                                    .clipShape(Capsule())
                            }
                            if g.hiddenCount > 0 {
                                Text("+\(g.hiddenCount) more")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(.thinMaterial.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        )
    }
}

private enum TagGrouper {
    struct Group: Identifiable {
        var id: String { key }
        let key: String
        let title: String
        let tags: [String]
        let displayLimit: Int

        var displayTags: [String] { Array(tags.prefix(displayLimit)) }
        var hiddenCount: Int { max(0, tags.count - displayLimit) }
    }

    static func grouped(tags: String?, perGroupLimit: Int = 14) -> [Group] {
        let raw = (tags ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if raw.isEmpty { return [] }

        var buckets: [String: [String]] = [:]
        for t in raw {
            let parts = t.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                let key = String(parts[0]).lowercased()
                let value = String(parts[1])
                buckets[key, default: []].append(value)
            } else {
                buckets["other", default: []].append(t)
            }
        }

        func titleFor(_ key: String) -> String {
            switch key {
            case "language": return "Language"
            case "artist": return "Artist"
            case "female": return "Female"
            case "male": return "Male"
            case "parody": return "Parody"
            case "character": return "Character"
            case "group": return "Group"
            case "tag": return "Tags"
            case "uploader": return "Uploader"
            case "other": return "Other"
            default:
                return key.prefix(1).uppercased() + key.dropFirst()
            }
        }

        let priority: [String] = ["language", "artist", "parody", "character", "group", "female", "male", "tag", "other"]

        var groups: [Group] = []
        groups.reserveCapacity(buckets.count)

        for (k, v) in buckets {
            let uniq = Array(Set(v)).sorted()
            groups.append(.init(key: k, title: titleFor(k), tags: uniq, displayLimit: perGroupLimit))
        }

        groups.sort { a, b in
            let ia = priority.firstIndex(of: a.key) ?? Int.max
            let ib = priority.firstIndex(of: b.key) ?? Int.max
            if ia != ib { return ia < ib }
            if a.tags.count != b.tags.count { return a.tags.count > b.tags.count }
            return a.title < b.title
        }

        return groups
    }
}

private struct ArchiveSideHeader: View {
    let profile: Profile
    let arcid: String
    let meta: ArchiveMetadata?
    let thumbnails: ThumbnailLoader
    let onRead: () -> Void
    let onEdit: () -> Void
    let onNotMatch: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                CoverThumb(profile: profile, arcid: arcid, thumbnails: thumbnails, size: .init(width: 64, height: 82))
                if meta?.isnew == true {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .padding(4)
                        .help("New")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let pages = meta?.pagecount {
                        Text("\(pages) pages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let ext = meta?.fileExtension, !ext.isEmpty {
                        Text(ext.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.55))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button { onRead() } label: {
                    Image(systemName: "book")
                        .imageScale(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open reader")

                Button { onEdit() } label: {
                    Image(systemName: "tag")
                        .imageScale(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Edit tags and metadata")

                Button("Not a match") { onNotMatch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .imageScale(.medium)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete this archive from LANraragi")
            }
        }
    }

    private var displayTitle: String {
        let t = meta?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "Untitled" : t
    }
}

private struct ArchiveSideDetails: View {
    let meta: ArchiveMetadata?
    let other: ArchiveMetadata?
    private static let addedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetaRow(label: "Pages", value: stringOrDash(meta?.pagecount.map(String.init)), different: meta?.pagecount != other?.pagecount)
            MetaRow(label: "Extension", value: stringOrDash(meta?.fileExtension), different: normalized(meta?.fileExtension) != normalized(other?.fileExtension))
            MetaRow(label: "Size", value: stringOrDash(sizeString(meta?.size)), different: meta?.size != other?.size)
            MetaRow(label: "Filename", value: stringOrDash(meta?.filename), different: normalized(meta?.filename) != normalized(other?.filename))
            MetaRow(
                label: "Added",
                value: stringOrDash(addedString(from: meta?.tags)),
                different: addedString(from: meta?.tags) != addedString(from: other?.tags),
                lineLimit: 1
            )
            MetaRow(label: "Summary", value: stringOrDash(meta?.summary), different: normalized(meta?.summary) != normalized(other?.summary))
            MetaRow(
                label: "Source",
                value: stringOrDash(sourceString(from: meta?.tags)),
                different: normalized(sourceString(from: meta?.tags)) != normalized(sourceString(from: other?.tags)),
                lineLimit: nil
            )
        }
        .font(.caption)
    }

    private func sizeString(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return Self.sizeFormatter.string(fromByteCount: Int64(bytes))
    }

    private func addedString(from tags: String?) -> String? {
        // LANraragi exposes date_added as a tag like `date_added:1712345678`.
        let raw = tags ?? ""
        for part in raw.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("date_added:") {
                let v = t.dropFirst("date_added:".count)
                if let ts = TimeInterval(v) {
                    let d = Date(timeIntervalSince1970: ts)
                    return Self.addedFormatter.string(from: d)
                }
            }
        }
        return nil
    }

    private func sourceString(from tags: String?) -> String? {
        // Common conventions: `source:<url>` or `source_url:<url>`.
        let raw = tags ?? ""
        var out: [String] = []
        out.reserveCapacity(2)
        for part in raw.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t.hasPrefix("source:") {
                out.append(String(t.dropFirst("source:".count)))
            } else if t.hasPrefix("source_url:") {
                out.append(String(t.dropFirst("source_url:".count)))
            }
        }
        let uniq = Array(Set(out)).sorted()
        return uniq.isEmpty ? nil : uniq.joined(separator: "\n")
    }

    private func normalized(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stringOrDash(_ s: String?) -> String {
        let t = normalized(s)
        return t.isEmpty ? "—" : t
    }
}

private struct MetaRow: View {
    let label: String
    let value: String
    let different: Bool
    var lineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Text(value)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .padding(.horizontal, 7)
                .background(different && value != "—" ? Color.yellow.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct ArchiveSideTags: View {
    let tagRows: [TagCompareGrouper.Row]
    let showingLeft: Bool

    var body: some View {
        if tagRows.isEmpty { return AnyView(EmptyView()) }

        let sideTags: (TagCompareGrouper.Row) -> ([String], Set<String>) = { r in
            if showingLeft {
                return (r.leftTags, r.leftOnly)
            } else {
                return (r.rightTags, r.rightOnly)
            }
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text("Tags")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(tagRows, id: \.key) { r in
                        let (tags, highlight) = sideTags(r)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(r.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            if tags.isEmpty {
                                Text("—")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.quaternary.opacity(0.35))
                                    .clipShape(Capsule())
                            } else {
                                TagChipWrap(tags: tags, highlight: highlight)
                            }
                        }
                        .padding(8)
                        .background(r.isDifferent ? Color.yellow.opacity(0.08) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        )
    }
}

private struct TagChipWrap: View {
    let tags: [String]
    let highlight: Set<String>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { t in
                let style: AnyShapeStyle = highlight.contains(t)
                    ? AnyShapeStyle(Color.yellow.opacity(0.18))
                    : AnyShapeStyle(.quaternary.opacity(0.55))
                Text(t)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(style)
                    }
            }
        }
    }
}

private enum TagCompareGrouper {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMM d yyyy h:mm a")
        return f
    }()

    struct Row {
        let key: String
        let title: String
        let leftTags: [String]
        let rightTags: [String]
        let leftOnly: Set<String>
        let rightOnly: Set<String>

        var isDifferent: Bool { !leftOnly.isEmpty || !rightOnly.isEmpty }
    }

    static func rows(tagsA: String?, tagsB: String?, maxGroups: Int, maxTagsPerGroup: Int) -> [Row] {
        let a = parse(tagsA)
        let b = parse(tagsB)
        if a.isEmpty, b.isEmpty { return [] }

        let priority: [String] = ["language", "artist", "parody", "character", "group", "female", "male", "tag", "other"]
        func titleFor(_ key: String) -> String {
            switch key {
            case "language": return "Language"
            case "artist": return "Artist"
            case "female": return "Female"
            case "male": return "Male"
            case "parody": return "Parody"
            case "character": return "Character"
            case "group": return "Group"
            case "tag": return "Tags"
            case "uploader": return "Uploader"
            case "date_added": return "Added"
            case "upload_time": return "Uploaded"
            case "other": return "Other"
            default:
                return key.prefix(1).uppercased() + key.dropFirst()
            }
        }

        let keys = Set(a.keys).union(b.keys)
        var ordered = Array(keys)
        ordered.sort { k1, k2 in
            let i1 = priority.firstIndex(of: k1) ?? Int.max
            let i2 = priority.firstIndex(of: k2) ?? Int.max
            if i1 != i2 { return i1 < i2 }
            return k1 < k2
        }

        var out: [Row] = []
        out.reserveCapacity(min(maxGroups, ordered.count))

        for k in ordered {
            let left = Array(a[k] ?? []).sorted()
            let right = Array(b[k] ?? []).sorted()
            if left.isEmpty, right.isEmpty { continue }

            let leftSet = Set(left)
            let rightSet = Set(right)
            let leftOnly = leftSet.subtracting(rightSet)
            let rightOnly = rightSet.subtracting(leftSet)

            out.append(.init(
                key: k,
                title: titleFor(k),
                leftTags: Array(left.prefix(maxTagsPerGroup)),
                rightTags: Array(right.prefix(maxTagsPerGroup)),
                leftOnly: leftOnly,
                rightOnly: rightOnly
            ))

            if out.count >= maxGroups { break }
        }

        return out
    }

    private static func parse(_ raw: String?) -> [String: Set<String>] {
        let parts = (raw ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty { return [:] }

        var buckets: [String: Set<String>] = [:]
        for t in parts {
            let p = t.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if p.count == 2 {
                let key = String(p[0]).lowercased()
                var value = String(p[1])
                value = formatUnixTimeIfApplicable(key: key, value: value) ?? value
                buckets[key, default: []].insert(value)
            } else {
                buckets["other", default: []].insert(t)
            }
        }
        return buckets
    }

    private static func formatUnixTimeIfApplicable(key: String, value: String) -> String? {
        // LANraragi often uses unix timestamps in tags like `date_added:1712345678` or `upload_time:...`.
        let keys = Set(["date_added", "upload_time", "last_read", "lastreadtime"])
        guard keys.contains(key) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = Double(trimmed) else { return nil }
        let seconds: TimeInterval
        // Heuristic: treat >= 1e12 as milliseconds.
        if raw >= 1_000_000_000_000 {
            seconds = raw / 1000.0
        } else {
            seconds = raw
        }
        guard seconds > 0 else { return nil }
        return timeFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}

private struct SyncedPagesGridView: View {
    let profile: Profile
    let arcidA: String
    let arcidB: String
    let archives: ArchiveLoader
    @Binding var scrollMinY: CGFloat

    @State private var pagesA: [URL] = []
    @State private var pagesB: [URL] = []
    @State private var errorA: String?
    @State private var errorB: String?
    @State private var reloadToken: Int = 0

    init(
        profile: Profile,
        arcidA: String,
        arcidB: String,
        archives: ArchiveLoader,
        scrollMinY: Binding<CGFloat> = .constant(0)
    ) {
        self.profile = profile
        self.arcidA = arcidA
        self.arcidB = arcidB
        self.archives = archives
        self._scrollMinY = scrollMinY
    }

    var body: some View {
        Group {
            if pagesA.isEmpty && pagesB.isEmpty && (errorA != nil || errorB != nil) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pages failed to load")
                        .font(.headline)
                    if let errorA {
                        Text("Left (\(arcidA)): \(errorA)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if let errorB {
                        Text("Right (\(arcidB)): \(errorB)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Button("Retry") { reloadToken &+= 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            } else if pagesA.isEmpty && pagesB.isEmpty && errorA == nil && errorB == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading pages…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                GeometryReader { geo in
                    let centerGap: CGFloat = 22
                    let sideWidth = max(140, (geo.size.width - centerGap) / 2.0)
                    let minTile: CGFloat = 140
                    let cols = max(2, min(6, Int(sideWidth / minTile)))
                    let tileWidth = (sideWidth - CGFloat(cols - 1) * 8) / CGFloat(cols)
                    let tileHeight = min(240, max(140, tileWidth * 1.35))

                    ScrollView(.vertical) {
                        // Must be inside the scroll content (document view) so `enclosingScrollView` resolves.
                        ScrollOffsetObserver { v in
                            scrollMinY = v
                        }
                        .frame(width: 1, height: 1)
                        .opacity(0.001)
                        .allowsHitTesting(false)

                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(stride(from: 0, to: max(pagesA.count, pagesB.count), by: cols).map { $0 }, id: \.self) { start in
                                HStack(alignment: .top, spacing: centerGap) {
                                    PageGridSide(
                                        profile: profile,
                                        pages: pagesA,
                                        unavailable: pagesA.isEmpty && errorA != nil,
                                        startIndex: start,
                                        count: cols,
                                        tileHeight: tileHeight,
                                        archives: archives
                                    )
                                    .frame(width: sideWidth)

                                    PageGridSide(
                                        profile: profile,
                                        pages: pagesB,
                                        unavailable: pagesB.isEmpty && errorB != nil,
                                        startIndex: start,
                                        count: cols,
                                        tileHeight: tileHeight,
                                        archives: archives
                                    )
                                    .frame(width: sideWidth)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    // On initial load, the pages viewport should be at least one tile tall.
                    .frame(minHeight: tileHeight + 12)
                    .overlay(alignment: .center) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let errorA {
                                Text("Left pages: \(errorA)")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                            if let errorB {
                                Text("Right pages: \(errorB)")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                            if errorA != nil || errorB != nil {
                                Button("Retry") { reloadToken &+= 1 }
                                    .controlSize(.mini)
                            }
                        }
                        .padding(10)
                        .background(.thinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(8)
                    }
                }
            }
        }
        // Keep the green box at least one tile high even while loading/errors.
        .frame(minHeight: ReviewLayout.minPagesViewportHeight)
        .task(id: "\(arcidA)|\(arcidB)|\(reloadToken)") {
            pagesA = []
            pagesB = []
            errorA = nil
            errorB = nil
            scrollMinY = 0

            async let aRes: Result<[URL], Error> = {
                do { return .success(try await archives.pageURLs(profile: profile, arcid: arcidA)) }
                catch { return .failure(error) }
            }()
            async let bRes: Result<[URL], Error> = {
                do { return .success(try await archives.pageURLs(profile: profile, arcid: arcidB)) }
                catch { return .failure(error) }
            }()

            let (a, b) = await (aRes, bRes)

            switch a {
            case .success(let pages): pagesA = pages
            case .failure(let err):
                if !(Task.isCancelled || ErrorPresenter.isCancellationLike(err)) {
                    errorA = ErrorPresenter.short(err)
                }
            }

            switch b {
            case .success(let pages): pagesB = pages
            case .failure(let err):
                if !(Task.isCancelled || ErrorPresenter.isCancellationLike(err)) {
                    errorB = ErrorPresenter.short(err)
                }
            }
        }
    }
}

private struct ScrollOffsetObserver: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: v)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private var onChange: (CGFloat) -> Void
        private weak var scrollView: NSScrollView?
        private weak var clipView: NSClipView?
        private var attachRetries: Int = 0

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
        }

        func attach(to view: NSView) {
            guard let sv = findScrollView(from: view) else {
                // SwiftUI sometimes inserts the representable before it has a superview; retry briefly.
                if attachRetries < 12 {
                    attachRetries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                        guard let self, let view else { return }
                        self.attach(to: view)
                    }
                }
                return
            }
            if scrollView === sv { return }
            scrollView = sv
            attachRetries = 0

            if let old = clipView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
            }

            let clip = sv.contentView
            clipView = clip
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )

            // Initial update.
            updateFromClip(clip)
        }

        private func findScrollView(from view: NSView) -> NSScrollView? {
            var v: NSView? = view
            while let cur = v {
                if let sv = cur as? NSScrollView { return sv }
                v = cur.superview
            }
            return view.enclosingScrollView
        }

        @objc private func boundsDidChange(_ note: Notification) {
            guard let clip = note.object as? NSClipView else { return }
            updateFromClip(clip)
        }

        private func updateFromClip(_ clip: NSClipView) {
            // At top: origin.y == 0. Scrolling down increases origin.y.
            let y = clip.bounds.origin.y
            // Match previous convention: negative when scrolling down.
            onChange(-y)
        }

        deinit {
            if let clipView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
            }
        }
    }
}

private struct SyncedScrollBridge: NSViewRepresentable {
    let id: Int
    @Binding var offsetY: CGFloat
    @Binding var activeID: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            id: id,
            getOffset: { offsetY },
            setOffset: { offsetY = $0 },
            getActive: { activeID },
            setActive: { activeID = $0 }
        )
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: v)
            context.coordinator.applyOffsetFromModel()
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView)
            context.coordinator.applyOffsetFromModel()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private let id: Int
        private let getOffset: () -> CGFloat
        private let setOffset: (CGFloat) -> Void
        private let getActive: () -> Int?
        private let setActive: (Int?) -> Void

        private weak var scrollView: NSScrollView?
        private weak var clipView: NSClipView?
        private var attachRetries: Int = 0
        private var isProgrammatic: Bool = false

        init(
            id: Int,
            getOffset: @escaping () -> CGFloat,
            setOffset: @escaping (CGFloat) -> Void,
            getActive: @escaping () -> Int?,
            setActive: @escaping (Int?) -> Void
        ) {
            self.id = id
            self.getOffset = getOffset
            self.setOffset = setOffset
            self.getActive = getActive
            self.setActive = setActive
        }

        func attach(to view: NSView) {
            guard let sv = findScrollView(from: view) else {
                if attachRetries < 12 {
                    attachRetries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                        guard let self, let view else { return }
                        self.attach(to: view)
                    }
                }
                return
            }
            if scrollView === sv { return }
            scrollView = sv
            attachRetries = 0

            if let old = clipView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
            }

            let clip = sv.contentView
            clipView = clip
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clip
            )
        }

        func applyOffsetFromModel() {
            guard let sv = scrollView, let clip = clipView else { return }
            // Only the non-active view should follow the shared offset.
            if getActive() == id { return }

            let target = max(0, getOffset())
            let current = clip.bounds.origin.y
            if abs(current - target) < 0.5 { return }

            isProgrammatic = true
            clip.scroll(to: NSPoint(x: 0, y: target))
            sv.reflectScrolledClipView(clip)
            isProgrammatic = false
        }

        private func findScrollView(from view: NSView) -> NSScrollView? {
            var v: NSView? = view
            while let cur = v {
                if let sv = cur as? NSScrollView { return sv }
                v = cur.superview
            }
            return view.enclosingScrollView
        }

        @objc private func boundsDidChange(_ note: Notification) {
            guard !isProgrammatic else { return }
            guard let clip = note.object as? NSClipView else { return }
            setActive(id)
            setOffset(clip.bounds.origin.y)
        }

        deinit {
            if let clipView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView)
            }
        }
    }
}

private struct PageGridSide: View {
    let profile: Profile
    let pages: [URL]
    let unavailable: Bool
    let startIndex: Int
    let count: Int
    let tileHeight: CGFloat
    let archives: ArchiveLoader

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: count),
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(0..<count, id: \.self) { offset in
                let idx = startIndex + offset
                PageThumbTile(
                    profile: profile,
                    pageIndex: idx,
                    url: (idx < pages.count) ? pages[idx] : nil,
                    unavailable: unavailable,
                    tileHeight: tileHeight,
                    archives: archives
                )
            }
        }
    }
}

private struct PageThumbTile: View {
    let profile: Profile
    let pageIndex: Int
    let url: URL?
    let unavailable: Bool
    let tileHeight: CGFloat
    let archives: ArchiveLoader

    @AppStorage("review.hoverPagePreview") private var hoverPreviewEnabled: Bool = true

    @State private var image: NSImage?
    @State private var fullImage: NSImage?
    @State private var errorText: String?
    @State private var hovering: Bool = false
    @State private var resolutionText: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary)

            if url == nil {
                Text(unavailable ? "Unavailable" : "Missing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else if let errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(8)
            } else {
                ProgressView()
            }

            if url != nil {
                Text("\(pageIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(6)
            }

            if let resolutionText, url != nil {
                Text(resolutionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial)
                    .clipShape(Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: tileHeight)
        .onHover { inside in
            guard hoverPreviewEnabled else { return }
            hovering = inside && (url != nil) && (image != nil)
        }
        .popover(isPresented: $hovering, arrowEdge: .trailing) {
            if let fullImage {
                Image(nsImage: fullImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 720, height: 920)
                    .padding(10)
            } else {
                ProgressView()
                    .padding(20)
                    .task {
                        await loadFullPreview()
                    }
            }
        }
        .task(id: url) {
            image = nil
            fullImage = nil
            errorText = nil
            resolutionText = nil
            guard let url else { return }
            do {
                let bytes = try await archives.bytes(profile: profile, url: url)
                let res = ImageDownsampler.resolutionText(from: bytes)
                let img = await MainActor.run { ImageDownsampler.thumbnail(from: bytes, maxPixelSize: 540) }
                if let img {
                    image = img
                    resolutionText = res
                } else {
                    errorText = "Decode failed"
                }
            } catch {
                if Task.isCancelled || ErrorPresenter.isCancellationLike(error) {
                    return
                }
                errorText = ErrorPresenter.short(error)
            }
        }
    }

    private func loadFullPreview() async {
        guard fullImage == nil, let url else { return }
        do {
            let bytes = try await archives.bytes(profile: profile, url: url)
            let img = await MainActor.run { ImageDownsampler.thumbnail(from: bytes, maxPixelSize: 1600) }
            await MainActor.run { fullImage = img }
        } catch {
            // Ignore preview failures; tiles still work.
        }
    }
}

// ImageDownsampler lives in Services/ImageDownsampler.swift
