import AppKit
import SwiftUI
import LanraragiKit

struct ReviewView: View {
    let profile: Profile
    let result: DuplicateScanResult
    let thumbnails: ThumbnailLoader

    @State private var selection: Int = 0
    @State private var minGroupSize: Int = 2
    @State private var query: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HSplitView {
                groupList
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)

                groupDetail
                    .frame(minWidth: 520)
            }
        }
        .onChange(of: query) { _, _ in
            selection = 0
        }
        .onChange(of: minGroupSize) { _, _ in
            selection = 0
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Duplicates")
                    .font(.title2)
                    .bold()
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                TextField("Filter by arcid…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)

                Stepper("Min group \(minGroupSize)", value: $minGroupSize, in: 2...25)
                    .font(.caption)
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var summaryLine: String {
        "Groups: \(filteredGroups.count)  •  Archives scanned: \(result.stats.archives)  •  Time: \(String(format: "%.1fs", result.stats.durationSeconds))"
    }

    private var filteredGroups: [[String]] {
        result.groups.filter { g in
            guard g.count >= minGroupSize else { return false }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return g.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func clampedSelection(max: Int) -> Int {
        if max <= 0 { return 0 }
        return min(selection, max - 1)
    }

    private var groupList: some View {
        VStack(spacing: 0) {
            List(filteredGroups.indices, id: \.self, selection: $selection) { idx in
                let g = filteredGroups[idx]
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Group \(idx + 1)")
                            .font(.headline)
                        Text("\(g.count) archives")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .tag(idx)
            }
        }
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var groupDetail: some View {
        let groups = filteredGroups
        if groups.isEmpty {
            return AnyView(
                ContentUnavailableView(
                    "No Results",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Try lowering the minimum group size or clearing the filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            )
        }

        let idx = clampedSelection(max: groups.count)
        let arcids = groups[idx]

        let columns = [
            GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 12),
        ]

        return AnyView(
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Group \(idx + 1) of \(groups.count)")
                        .font(.headline)
                    Text("\(arcids.count) archives")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button("Prev") { selection = max(0, idx - 1) }
                        .disabled(idx == 0)
                    Button("Next") { selection = min(groups.count - 1, idx + 1) }
                        .disabled(idx + 1 >= groups.count)
                }
            }

            Divider()

            // Vertical scrollbar + stable layout when the window is resized.
            ScrollView(.vertical) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(arcids, id: \.self) { arcid in
                        CoverTile(profile: profile, arcid: arcid, thumbnails: thumbnails)
                    }
                }
                .padding(.vertical, 6)
            }

            Text("Tip: right-click a cover for actions (copy arcid). Deletion controls are coming next.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
    }
}

private struct CoverTile: View {
    let profile: Profile
    let arcid: String
    let thumbnails: ThumbnailLoader

    @State private var image: NSImage?
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.quaternary)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(6)
                } else if errorText != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 260)

            Text(arcid)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
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
