import AppKit
import SwiftUI
import LanraragiKit

struct PairReviewView: View {
    let profile: Profile
    let result: DuplicateScanResult
    let thumbnails: ThumbnailLoader
    let archives: ArchiveLoader

    let markNotDuplicate: (DuplicateScanResult.Pair) -> Void
    let deleteArchive: (String) async throws -> Void

    @State private var selection: Int?
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
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)

                pairDetail
                    .frame(minWidth: 520)
            }
        }
        .onChange(of: query) { _, _ in selection = nil }
        .onChange(of: filterExact) { _, _ in selection = nil }
        .onChange(of: filterSimilar) { _, _ in selection = nil }
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
                Toggle("Exact cover", isOn: $filterExact)
                    .toggleStyle(.switch)
                    .font(.caption)
                Toggle("Similar cover", isOn: $filterSimilar)
                    .toggleStyle(.switch)
                    .font(.caption)

                TextField("Filter by arcid…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
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

    private var pairList: some View {
        List(filteredPairs.indices, id: \.self, selection: $selection) { idx in
            let p = filteredPairs[idx]
            PairRowView(
                profile: profile,
                pair: p,
                thumbnails: thumbnails,
                markNotDuplicate: markNotDuplicate
            )
                .tag(idx)
        }
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var pairDetail: some View {
        let pairs = filteredPairs
        if pairs.isEmpty {
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

        let idx = min(max(0, selection), pairs.count - 1)
        let p = pairs[idx]
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
                goBack: { self.selection = nil },
                goNext: {
                    self.selection = min(pairs.count - 1, idx + 1)
                },
                goPrev: {
                    self.selection = max(0, idx - 1)
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
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                CoverThumb(profile: profile, arcid: pair.arcidA, thumbnails: thumbnails)
                CoverThumb(profile: profile, arcid: pair.arcidB, thumbnails: thumbnails)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(labelText)
                    .font(.headline)
                Text("\(pair.arcidA)  ↔  \(pair.arcidB)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Copy Arcid A") { copy(pair.arcidA) }
            Button("Copy Arcid B") { copy(pair.arcidB) }
            Divider()
            Button("Mark As Not A Match") { markNotDuplicate(pair) }
        }
    }

    private var labelText: String {
        switch pair.reason {
        case .exactCover:
            return "Exact cover match"
        case .similarCover:
            let d = pair.dHashDistance.map(String.init) ?? "?"
            let a = pair.aHashDistance.map(String.init) ?? "?"
            return "Similar cover (d=\(d), a=\(a))"
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
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
    let goBack: () -> Void
    let goNext: () -> Void
    let goPrev: () -> Void

    @State private var confirmDeleteArcid: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            actions

            HSplitView {
                ArchiveColumn(profile: profile, arcid: pair.arcidA, thumbnails: thumbnails, archives: archives)
                ArchiveColumn(profile: profile, arcid: pair.arcidB, thumbnails: thumbnails, archives: archives)
            }

            Divider()

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

    private var actions: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compare Pair")
                    .font(.headline)
                Text(reasonText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Back") { goBack() }
            Button("Prev") { goPrev() }
            Button("Next") { goNext() }

            Button("Not A Match") { markNotDuplicate(pair) }

            Button("Delete Left", role: .destructive) { confirmDeleteArcid = pair.arcidA }
            Button("Delete Right", role: .destructive) { confirmDeleteArcid = pair.arcidB }

            Button("Copy Both Arcids") {
                let s = "\(pair.arcidA)\n\(pair.arcidB)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
    }

    private var reasonText: String {
        switch pair.reason {
        case .exactCover:
            return "Exact cover match"
        case .similarCover:
            let d = pair.dHashDistance.map(String.init) ?? "?"
            let a = pair.aHashDistance.map(String.init) ?? "?"
            return "Similar cover (d=\(d), a=\(a))"
        }
    }

    private var syncedPageCompare: some View {
        SyncedPagesView(profile: profile, arcidA: pair.arcidA, arcidB: pair.arcidB, archives: archives)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ArchiveColumn: View {
    let profile: Profile
    let arcid: String
    let thumbnails: ThumbnailLoader
    let archives: ArchiveLoader

    @State private var meta: ArchiveMetadata?
    @State private var metaError: String?
    @State private var rawMeta: String?
    @State private var rawMetaError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            // Pages are shown in a synced compare scroller below.
            Text(metaLineSecondary)
                .font(.caption2)
                .foregroundStyle(.secondary)

            DisclosureGroup("All metadata") {
                if let rawMetaError {
                    Text(rawMetaError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if let rawMeta {
                    Text(rawMeta)
                        .font(.caption2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: arcid) {
            meta = nil
            metaError = nil
            rawMeta = nil
            rawMetaError = nil

            do {
                meta = try await archives.metadata(profile: profile, arcid: arcid)
            } catch {
                metaError = String(describing: error)
            }

            do {
                rawMeta = try await archives.metadataPrettyJSON(profile: profile, arcid: arcid)
            } catch {
                rawMetaError = String(describing: error)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            CoverThumb(profile: profile, arcid: arcid, thumbnails: thumbnails)

            VStack(alignment: .leading, spacing: 4) {
                Text(meta?.title?.isEmpty == false ? meta!.title! : arcid)
                    .font(.headline)
                    .lineLimit(2)

                if let metaError {
                    Text("Info error: \(metaError)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else {
                    Text(metaLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text(arcid)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer()
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let c = meta?.category, !c.isEmpty { parts.append("Category: \(c)") }
        if let p = meta?.pagecount { parts.append("Pages: \(p)") }
        if let f = meta?.filename, !f.isEmpty { parts.append("File: \(f)") }
        if let e = meta?.fileExtension, !e.isEmpty { parts.append("Ext: \(e)") }
        if let t = meta?.tags, !t.isEmpty { parts.append("Tags: \(t)") }
        if parts.isEmpty { return "Loading info…" }
        return parts.joined(separator: "  •  ")
    }

    private var metaLineSecondary: String {
        if metaError != nil {
            return "Metadata failed to load."
        }
        if let s = meta?.summary, !s.isEmpty {
            return s
        }
        return ""
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

    @State private var image: NSImage?
    @State private var errorText: String?

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
        .task(id: url) {
            image = nil
            errorText = nil
            guard let url else { return }
            do {
                let bytes = try await archives.bytes(profile: profile, url: url)
                let img = await MainActor.run { NSImage(data: bytes) }
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
}
