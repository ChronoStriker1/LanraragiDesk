import AppKit
import SwiftUI
import LanraragiKit

struct DuplicateResultsView: View {
    let profile: Profile
    let result: DuplicateScanResult
    let thumbnails: ThumbnailLoader

    @State private var selection: Int?

    var body: some View {
        NavigationSplitView {
            List(result.groups.indices, id: \.self, selection: $selection) { idx in
                let g = result.groups[idx]
                VStack(alignment: .leading, spacing: 4) {
                    Text("Group \(idx + 1)")
                        .font(.headline)
                    Text("\(g.count) archives")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Duplicates")
        } detail: {
            if let sel = selection, result.groups.indices.contains(sel) {
                DuplicateGroupDetailView(
                    profile: profile,
                    arcids: result.groups[sel],
                    thumbnails: thumbnails,
                    stats: result.stats
                )
            } else {
                ContentUnavailableView(
                    "Select a group",
                    systemImage: "square.stack.3d.up",
                    description: Text("Pick a duplicate group to preview covers.")
                )
            }
        }
        .onAppear {
            if selection == nil, !result.groups.isEmpty {
                selection = 0
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}

private struct DuplicateGroupDetailView: View {
    let profile: Profile
    let arcids: [String]
    let thumbnails: ThumbnailLoader
    let stats: DuplicateScanStats

    private let cols = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 14),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                LazyVGrid(columns: cols, alignment: .leading, spacing: 14) {
                    ForEach(arcids, id: \.self) { arcid in
                        ThumbnailTile(profile: profile, arcid: arcid, thumbnails: thumbnails)
                    }
                }
            }
            .padding(18)
        }
        .navigationTitle("Group (\(arcids.count))")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scan Stats")
                .font(.headline)
            Text("Archives: \(stats.archives)  •  Groups: \(stats.exactGroups) exact  •  Approx edges: \(stats.approximateEdges)  •  Skipped buckets: \(stats.skippedBuckets)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ThumbnailTile: View {
    let profile: Profile
    let arcid: String
    let thumbnails: ThumbnailLoader

    @State private var image: NSImage?
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(6)
                } else if errorText != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 220)

            Text(arcid)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .contextMenu {
            Button("Copy Arcid") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(arcid, forType: .string)
            }
        }
        .onAppear {
            if image != nil || errorText != nil { return }
            task?.cancel()
            task = Task {
                do {
                    let bytes = try await thumbnails.thumbnailBytes(profile: profile, arcid: arcid)
                    let img = await MainActor.run { NSImage(data: bytes) }
                    await MainActor.run { image = img }
                } catch {
                    await MainActor.run { errorText = String(describing: error) }
                }
            }
        }
        .onDisappear {
            task?.cancel()
            task = nil
        }
    }
}
