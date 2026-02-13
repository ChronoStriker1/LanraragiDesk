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
    @State private var filterExact: Bool = true
    @State private var filterSimilar: Bool = true
    @State private var errorText: String?

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
                    .frame(minWidth: 240, idealWidth: 290, maxWidth: 360)

                pairDetail
                    .frame(minWidth: 520)
            }
        }
        .onChange(of: query) { _, _ in selection = nil }
        .onChange(of: filterExact) { _, _ in selection = nil }
        .onChange(of: filterSimilar) { _, _ in selection = nil }
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
                Toggle("Exact", isOn: $filterExact)
                    .toggleStyle(.switch)
                    .font(.caption)
                Toggle("Similar", isOn: $filterSimilar)
                    .toggleStyle(.switch)
                    .font(.caption)

                TextField("Search ID…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                Toggle("Hover preview", isOn: $hoverPagePreview)
                    .toggleStyle(.switch)
                    .font(.caption)
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var filteredPairs: [DuplicateScanResult.Pair] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.pairs.filter { p in
            if p.reason == .exactCover, !filterExact { return false }
            if p.reason == .similarCover, !filterSimilar { return false }
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
        List(selection: $selection) {
            if filterExact {
                Section("Exact cover") {
                    ForEach(exactPairs, id: \.self) { p in
                        PairRowView(
                            profile: profile,
                            pair: p,
                            thumbnails: thumbnails,
                            archives: archives,
                            markNotDuplicate: { pair in
                                let next = nextPair(after: pair)
                                markNotDuplicate(pair)
                                selection = next
                            }
                        )
                        .tag(p)
                    }
                }
            }

            if filterSimilar {
                Section("Similar cover") {
                    ForEach(similarPairs, id: \.self) { p in
                        PairRowView(
                            profile: profile,
                            pair: p,
                            thumbnails: thumbnails,
                            archives: archives,
                            markNotDuplicate: { pair in
                                let next = nextPair(after: pair)
                                markNotDuplicate(pair)
                                selection = next
                            }
                        )
                        .tag(p)
                    }
                }
            }
        }
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func orderedPairsForNavigation() -> [DuplicateScanResult.Pair] {
        var out: [DuplicateScanResult.Pair] = []
        if filterExact { out.append(contentsOf: exactPairs) }
        if filterSimilar { out.append(contentsOf: similarPairs) }
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
    let archives: ArchiveLoader
    let markNotDuplicate: (DuplicateScanResult.Pair) -> Void

    @State private var titleA: String?
    @State private var titleB: String?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                CoverThumb(profile: profile, arcid: pair.arcidA, thumbnails: thumbnails)
                CoverThumb(profile: profile, arcid: pair.arcidB, thumbnails: thumbnails)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(titleLine)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Not a match") { markNotDuplicate(pair) }
        }
        .task(id: "\(pair.arcidA)|\(pair.arcidB)") {
            titleA = nil
            titleB = nil
            do {
                async let a = archives.metadata(profile: profile, arcid: pair.arcidA)
                async let b = archives.metadata(profile: profile, arcid: pair.arcidB)
                let (ma, mb) = try await (a, b)
                titleA = ma.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                titleB = mb.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                // Keep the row usable even if titles fail to load.
            }
        }
    }

    private var titleLine: String {
        let left = (titleA?.isEmpty == false) ? titleA! : "Untitled"
        let right = (titleB?.isEmpty == false) ? titleB! : "Untitled"
        if titleA == nil || titleB == nil {
            return "Loading titles…"
        }
        if left == right {
            return left
        }
        return "\(left) ↔ \(right)"
    }

    private var subtitle: String {
        switch pair.reason {
        case .exactCover:
            return "Exact cover"
        case .similarCover:
            return "Similar cover"
        }
    }
}

private struct CoverThumb: View {
    let profile: Profile
    let arcid: String
    let thumbnails: ThumbnailLoader

    @State private var image: NSImage?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(4)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .frame(width: 56, height: 72)
        .onAppear {
            if image != nil { return }
            task?.cancel()
            task = Task {
                if let img = await fetch() {
                    await MainActor.run { image = img }
                }
            }
        }
        .onDisappear {
            task?.cancel()
            task = nil
        }
    }

    private func fetch() async -> NSImage? {
        do {
            let bytes = try await thumbnails.thumbnailBytes(profile: profile, arcid: arcid)
            return await MainActor.run { NSImage(data: bytes) }
        } catch {
            return nil
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            compareHeader

            MetadataCompareBlock(
                profile: profile,
                arcidA: pair.arcidA,
                arcidB: pair.arcidB,
                thumbnails: thumbnails,
                archives: archives
                ,
                onDeleteLeft: { confirmDeleteArcid = pair.arcidA },
                onDeleteRight: { confirmDeleteArcid = pair.arcidB },
                onNotAMatch: {
                    markNotDuplicate(pair)
                    goNext()
                }
            )

            syncedPageCompare
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
    }

    private var compareHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare")
                    .font(.headline)
                Text(matchKindText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private var matchKindText: String {
        switch pair.reason {
        case .exactCover:
            return "Exact cover match"
        case .similarCover:
            return "Similar cover match"
        }
    }

    private var syncedPageCompare: some View {
        SyncedPagesView(profile: profile, arcidA: pair.arcidA, arcidB: pair.arcidB, archives: archives)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MetadataCompareBlock: View {
    let profile: Profile
    let arcidA: String
    let arcidB: String
    let thumbnails: ThumbnailLoader
    let archives: ArchiveLoader
    let onDeleteLeft: () -> Void
    let onDeleteRight: () -> Void
    let onNotAMatch: () -> Void

    @State private var metaA: ArchiveMetadata?
    @State private var metaB: ArchiveMetadata?
    @State private var err: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if let err {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            HStack(alignment: .top, spacing: 12) {
                ArchiveInfoColumn(meta: metaA)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Not a match") { onNotAMatch() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 8)

                ArchiveInfoColumn(meta: metaB)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: "\(arcidA)|\(arcidB)") {
            metaA = nil
            metaB = nil
            err = nil

            do {
                async let a = archives.metadata(profile: profile, arcid: arcidA)
                async let b = archives.metadata(profile: profile, arcid: arcidB)
                metaA = try await a
                metaB = try await b
            } catch {
                err = "Metadata failed to load: \(error)"
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 8) {
                CoverThumb(profile: profile, arcid: arcidA, thumbnails: thumbnails)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metaA?.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? metaA!.title! : "Untitled")
                        .font(.headline)
                        .lineLimit(2)
                    Text(arcidA)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button(role: .destructive) { onDeleteLeft() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete this archive")
                .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                CoverThumb(profile: profile, arcid: arcidB, thumbnails: thumbnails)
                VStack(alignment: .leading, spacing: 2) {
                    Text(metaB?.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? metaB!.title! : "Untitled")
                        .font(.headline)
                        .lineLimit(2)
                    Text(arcidB)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button(role: .destructive) { onDeleteRight() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete this archive")
                .padding(.leading, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ArchiveInfoColumn: View {
    let meta: ArchiveMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                InfoChip(label: "Category", value: meta?.category)
                InfoChip(label: "Pages", value: meta?.pagecount.map(String.init))
                InfoChip(label: "Ext", value: meta?.fileExtension)
            }

            if let summary = meta?.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Summary")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .font(.caption)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                .padding(10)
                .background(.thinMaterial.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            TagGroupsView(tags: meta?.tags)
        }
        .font(.caption)
    }
}

private struct InfoChip: View {
    let label: String
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(displayValue)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var displayValue: String {
        let v = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return v.isEmpty ? "—" : v
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

private struct SyncedPagesView: View {
    let profile: Profile
    let arcidA: String
    let arcidB: String
    let archives: ArchiveLoader

    @State private var pagesA: [URL] = []
    @State private var pagesB: [URL] = []
    @State private var errorText: String?

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
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(0..<max(pagesA.count, pagesB.count), id: \.self) { idx in
                            PageCompareRow(
                                profile: profile,
                                idx: idx,
                                urlA: idx < pagesA.count ? pagesA[idx] : nil,
                                urlB: idx < pagesB.count ? pagesB[idx] : nil,
                                archives: archives
                            )
                        }
                    }
                    .padding(.vertical, 8)
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

private struct PageCompareRow: View {
    let profile: Profile
    let idx: Int
    let urlA: URL?
    let urlB: URL?
    let archives: ArchiveLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Page \(idx + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                PageImageTile(profile: profile, url: urlA, archives: archives)
                PageImageTile(profile: profile, url: urlB, archives: archives)
            }
        }
    }
}

private struct PageImageTile: View {
    let profile: Profile
    let url: URL?
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
        }
        .frame(maxWidth: .infinity)
        .frame(height: 230)
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
