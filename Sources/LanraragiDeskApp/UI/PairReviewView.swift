import AppKit
import SwiftUI
import LanraragiKit

struct PairReviewView: View {
    let profile: Profile
    let result: DuplicateScanResult
    let thumbnails: ThumbnailLoader
    let archives: ArchiveLoader

    let markNotDuplicate: (DuplicateScanResult.Pair) -> Void

    @State private var selection: Int = 0
    @State private var query: String = ""
    @State private var filterExact: Bool = true
    @State private var filterSimilar: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HSplitView {
                pairList
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)

                pairDetail
                    .frame(minWidth: 520)
            }
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onChange(of: filterExact) { _, _ in selection = 0 }
        .onChange(of: filterSimilar) { _, _ in selection = 0 }
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
            PairRowView(profile: profile, pair: p, thumbnails: thumbnails)
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

        let idx = min(max(0, selection), pairs.count - 1)
        let p = pairs[idx]
        return AnyView(
            PairCompareView(
                profile: profile,
                pair: p,
                thumbnails: thumbnails,
                archives: archives,
                markNotDuplicate: markNotDuplicate
            )
        )
    }
}

private struct PairRowView: View {
    let profile: Profile
    let pair: DuplicateScanResult.Pair
    let thumbnails: ThumbnailLoader

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            actions

            HSplitView {
                ArchiveColumn(
                    profile: profile,
                    arcid: pair.arcidA,
                    thumbnails: thumbnails,
                    archives: archives
                )

                ArchiveColumn(
                    profile: profile,
                    arcid: pair.arcidB,
                    thumbnails: thumbnails,
                    archives: archives
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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

            Button("Not A Duplicate") {
                markNotDuplicate(pair)
            }

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
}

private struct ArchiveColumn: View {
    let profile: Profile
    let arcid: String
    let thumbnails: ThumbnailLoader
    let archives: ArchiveLoader

    @State private var meta: ArchiveMetadata?
    @State private var pages: [URL] = []
    @State private var metaError: String?
    @State private var pagesError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            if let pagesError {
                Text("Pages error: \(pagesError)")
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
            } else if pages.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading pages…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { idx, url in
                            PageImageTile(profile: profile, idx: idx, url: url, archives: archives)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: arcid) {
            meta = nil
            pages = []
            metaError = nil
            pagesError = nil

            do {
                meta = try await archives.metadata(profile: profile, arcid: arcid)
            } catch {
                metaError = String(describing: error)
            }

            do {
                pages = try await archives.pageURLs(profile: profile, arcid: arcid)
            } catch {
                pagesError = String(describing: error)
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
        if let t = meta?.tags, !t.isEmpty { parts.append("Tags: \(t)") }
        if parts.isEmpty { return "Loading info…" }
        return parts.joined(separator: "  •  ")
    }
}

private struct PageImageTile: View {
    let profile: Profile
    let idx: Int
    let url: URL
    let archives: ArchiveLoader

    @State private var image: NSImage?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Page \(idx + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)

                if let image {
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
        }
        .task(id: url) {
            image = nil
            errorText = nil
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

