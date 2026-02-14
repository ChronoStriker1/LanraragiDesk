import AppKit
import ImageIO
import SwiftUI
import LanraragiKit

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
                    .frame(minWidth: 260, idealWidth: 280, maxWidth: 340)

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
            LazyVStack(alignment: .center, spacing: 6) {
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
            .padding(8)
        }
        .scrollIndicators(.visible)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        )
    }
}

private struct PairRowView: View {
    let profile: Profile
    let pair: DuplicateScanResult.Pair
    let thumbnails: ThumbnailLoader
    let markNotDuplicate: (DuplicateScanResult.Pair) -> Void

    var body: some View {
        HStack(spacing: 8) {
            CoverThumb(profile: profile, arcid: pair.arcidA, thumbnails: thumbnails, size: .init(width: 112, height: 144))
            CoverThumb(profile: profile, arcid: pair.arcidB, thumbnails: thumbnails, size: .init(width: 112, height: 144))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(reasonColor.opacity(0.9))
                .frame(width: 4)
                .padding(.vertical, 8)
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
    @State private var metaA: ArchiveMetadata?
    @State private var metaB: ArchiveMetadata?
    @State private var pagesScrollMinY: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topBar
                .animation(.snappy(duration: 0.2), value: detailsCollapsed)

            SyncedPagesGridView(
                profile: profile,
                arcidA: pair.arcidA,
                arcidB: pair.arcidB,
                archives: archives,
                scrollMinY: $pagesScrollMinY
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        .task(id: "\(pair.arcidA)|\(pair.arcidB)") {
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
    }

    private var detailsCollapsed: Bool {
        // `minY` becomes negative as you scroll down.
        pagesScrollMinY < -4
    }

    private var topBar: some View {
        VStack(alignment: .leading, spacing: detailsCollapsed ? 0 : 10) {
            HStack(alignment: .top, spacing: 12) {
                ArchiveSideHeader(
                    profile: profile,
                    arcid: pair.arcidA,
                    meta: metaA,
                    thumbnails: thumbnails,
                    collapsed: detailsCollapsed
                )

                Divider().padding(.vertical, 6)

                HStack(spacing: 10) {
                    Button(role: .destructive) { confirmDeleteArcid = pair.arcidA } label: {
                        Image(systemName: "trash")
                            .imageScale(.medium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(detailsCollapsed ? .mini : .small)
                    .help("Delete left archive from LANraragi")

                    Button("Not a match") {
                        markNotDuplicate(pair)
                        goNext()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(detailsCollapsed ? .small : .regular)

                    Button(role: .destructive) { confirmDeleteArcid = pair.arcidB } label: {
                        Image(systemName: "trash")
                            .imageScale(.medium)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(detailsCollapsed ? .mini : .small)
                    .help("Delete right archive from LANraragi")
                }

                Divider().padding(.vertical, 6)

                ArchiveSideHeader(
                    profile: profile,
                    arcid: pair.arcidB,
                    meta: metaB,
                    thumbnails: thumbnails,
                    collapsed: detailsCollapsed
                )
            }

            if !detailsCollapsed {
                ArchiveCompareDetails(metaA: metaA, metaB: metaB)
            }
        }
        .padding(detailsCollapsed ? 6 : 10)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Prevent this header block from stretching vertically and creating empty space.
        .fixedSize(horizontal: false, vertical: true)
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
    let collapsed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CoverThumb(profile: profile, arcid: arcid, thumbnails: thumbnails, size: .init(width: 64, height: 82))

            VStack(alignment: .leading, spacing: collapsed ? 4 : 6) {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(collapsed ? 1 : 2)

                if !collapsed {
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
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayTitle: String {
        let t = meta?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "Untitled" : t
    }
}

private struct ArchiveCompareDetails: View {
    let metaA: ArchiveMetadata?
    let metaB: ArchiveMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            diffRow("Pages", a: metaA?.pagecount.map(String.init), b: metaB?.pagecount.map(String.init))
            diffRow("Extension", a: metaA?.fileExtension, b: metaB?.fileExtension)
            diffRow("Filename", a: metaA?.filename, b: metaB?.filename, lineLimit: 2)
            diffRow("Summary", a: metaA?.summary, b: metaB?.summary, lineLimit: 2)
            diffRow("New", a: metaA?.isnew.map { $0 ? "Yes" : "No" }, b: metaB?.isnew.map { $0 ? "Yes" : "No" })
            diffRow("Progress", a: metaA?.progress.map(String.init), b: metaB?.progress.map(String.init))
            diffRow("Last Read", a: metaA?.lastreadtime.map(String.init), b: metaB?.lastreadtime.map(String.init))
            }
            .font(.caption)

            TagGroupCompareView(tagsA: metaA?.tags, tagsB: metaB?.tags)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func diffRow(_ label: String, a: String?, b: String?, lineLimit: Int = 1) -> some View {
        let left = (a?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? a! : "—"
        let right = (b?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? b! : "—"
        let different = left != right && left != "—" && right != "—"

        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)

            Text(left)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(different ? Color.yellow.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(right)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(different ? Color.yellow.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct TagGroupCompareView: View {
    let tagsA: String?
    let tagsB: String?

    var body: some View {
        let rows = TagCompareGrouper.rows(tagsA: tagsA, tagsB: tagsB, maxGroups: 4, maxTagsPerGroup: 12)
        if rows.isEmpty {
            return AnyView(EmptyView())
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Text("Tags")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.key) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(r.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            HStack(alignment: .top, spacing: 10) {
                                TagChipWrap(
                                    tags: r.leftTags,
                                    highlight: r.leftOnly
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                                TagChipWrap(
                                    tags: r.rightTags,
                                    highlight: r.rightOnly
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(6)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { t in
                let style: AnyShapeStyle = highlight.contains(t)
                    ? AnyShapeStyle(Color.yellow.opacity(0.18))
                    : AnyShapeStyle(.quaternary.opacity(0.55))
                Text(t)
                    .font(.caption2)
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
                let value = String(p[1])
                buckets[key, default: []].insert(value)
            } else {
                buckets["other", default: []].insert(t)
            }
        }
        return buckets
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
    @State private var errorText: String?

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
            if let errorText {
                Text("Pages error: \(errorText)")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if pagesA.isEmpty || pagesB.isEmpty {
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
                        LazyVStack(alignment: .leading, spacing: 12) {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ScrollMinYPreferenceKey.self,
                                    value: proxy.frame(in: .named("pagesScroll")).minY
                                )
                            }
                            .frame(height: 1)
                            .opacity(0.001)

                            ForEach(stride(from: 0, to: max(pagesA.count, pagesB.count), by: cols).map { $0 }, id: \.self) { start in
                                HStack(alignment: .top, spacing: centerGap) {
                                    PageGridSide(
                                        profile: profile,
                                        pages: pagesA,
                                        startIndex: start,
                                        count: cols,
                                        tileHeight: tileHeight,
                                        archives: archives
                                    )
                                    .frame(width: sideWidth)

                                    PageGridSide(
                                        profile: profile,
                                        pages: pagesB,
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
                    .coordinateSpace(name: "pagesScroll")
                    .onPreferenceChange(ScrollMinYPreferenceKey.self) { v in
                        scrollMinY = v
                    }
                    .overlay(alignment: .center) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(width: 1)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .task(id: "\(arcidA)|\(arcidB)") {
            pagesA = []
            pagesB = []
            errorText = nil
            do {
                async let a = archives.pageURLs(profile: profile, arcid: arcidA)
                async let b = archives.pageURLs(profile: profile, arcid: arcidB)
                pagesA = try await a
                pagesB = try await b
            } catch {
                errorText = String(describing: error)
            }
        }
    }
}

private struct ScrollMinYPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PageGridSide: View {
    let profile: Profile
    let pages: [URL]
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
    let tileHeight: CGFloat
    let archives: ArchiveLoader

    @AppStorage("review.hoverPagePreview") private var hoverPreviewEnabled: Bool = true

    @State private var image: NSImage?
    @State private var fullImage: NSImage?
    @State private var errorText: String?
    @State private var hovering: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary)

            if url == nil {
                Text("Missing")
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
            guard let url else { return }
            do {
                let bytes = try await archives.bytes(profile: profile, url: url)
                let img = await MainActor.run { ImageDownsampler.thumbnail(from: bytes, maxPixelSize: 540) }
                if let img {
                    image = img
                } else {
                    errorText = "Decode failed"
                }
            } catch {
                errorText = String(describing: error)
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

private enum ImageDownsampler {
    static func thumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        guard maxPixelSize > 0 else { return NSImage(data: data) }
        let cfData = data as CFData
        guard let src = CGImageSourceCreateWithData(cfData, nil) else { return NSImage(data: data) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return NSImage(data: data) }
        return NSImage(cgImage: cg, size: .zero)
    }
}
