import AppKit
import SwiftUI
import LanraragiKit

struct MainPageCarouselsView: View {
    @EnvironmentObject private var appModel: AppModel

    let profile: Profile

    @StateObject private var vm = MainPageCarouselsViewModel()
    @State private var expanded: Bool = false
    @AppStorage("library.mainPageCarousels.selectedKind") private var selectedKindRaw: String = MainPageCarouselKind.newArchives.rawValue
    @State private var editingMeta: EditorRoute?

    private var selectedKind: MainPageCarouselKind {
        MainPageCarouselKind(rawValue: selectedKindRaw) ?? .newArchives
    }

    private var selectedKindBinding: Binding<MainPageCarouselKind> {
        Binding(
            get: { selectedKind },
            set: { selectedKindRaw = $0.rawValue }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Picker("Carousel", selection: selectedKindBinding) {
                        ForEach(MainPageCarouselKind.allCases, id: \.rawValue) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)

                    Spacer()

                    Button("Refresh") {
                        vm.reload(profile: profile, archives: appModel.archives, kind: selectedKind)
                    }
                    .buttonStyle(.borderedProminent)
                }

                MainPageCarouselSection(
                    kind: selectedKind,
                    state: vm.state(for: selectedKind),
                    profile: profile,
                    onRefresh: {
                        vm.reload(profile: profile, archives: appModel.archives, kind: selectedKind)
                    },
                    onEditMetadata: { arcid in
                        editingMeta = EditorRoute(arcid: arcid)
                    }
                )
                .environmentObject(appModel)
            }
            .padding(.top, 12)
        } label: {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(selectedKind.title)
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: profile.id) {
            vm.reload(profile: profile, archives: appModel.archives, kind: selectedKind)
        }
        .onChange(of: profile.id) { _, _ in
            vm.reload(profile: profile, archives: appModel.archives, kind: selectedKind)
        }
        .onChange(of: selectedKindRaw) { _, _ in
            vm.reload(profile: profile, archives: appModel.archives, kind: selectedKind)
        }
        .sheet(item: $editingMeta) { route in
            ArchiveMetadataEditorView(
                profile: profile,
                arcid: route.arcid,
                initialMeta: nil,
                archives: appModel.archives,
                onSaved: { _ in
                    vm.reload(profile: profile, archives: appModel.archives, kind: selectedKind)
                },
                onDelete: { arcid in
                    do {
                        try await appModel.archives.deleteArchive(profile: profile, arcid: arcid)
                        await appModel.thumbnails.invalidate(profile: profile, arcid: arcid)
                        appModel.selection.remove(arcid)
                        vm.reload(profile: profile, archives: appModel.archives, kind: selectedKind)
                        appModel.activity.add(.init(kind: .action, title: "Deleted archive", detail: arcid))
                    } catch {
                        appModel.activity.add(.init(kind: .error, title: "Delete archive failed", detail: "\(arcid)\n\(error)"))
                        throw error
                    }
                }
            )
            .environmentObject(appModel)
        }
    }
}

private struct EditorRoute: Identifiable, Hashable {
    let arcid: String
    var id: String { arcid }
}

@MainActor
final class MainPageCarouselsViewModel: ObservableObject {
    struct CarouselState {
        var items: [ArchiveMetadata] = []
        var isLoading: Bool = false
        var errorText: String?
    }

    @Published private(set) var newArchives = CarouselState()
    @Published private(set) var untaggedArchives = CarouselState()

    private var loadTask: Task<Void, Never>?

    func state(for kind: MainPageCarouselKind) -> CarouselState {
        switch kind {
        case .newArchives:
            return newArchives
        case .untaggedArchives:
            return untaggedArchives
        }
    }

    func reload(profile: Profile, archives: ArchiveLoader, kind: MainPageCarouselKind) {
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            await self.load(profile: profile, archives: archives, kind: kind)
        }
    }

    private func load(profile: Profile, archives: ArchiveLoader, kind: MainPageCarouselKind) async {
        setLoading(kind, true)

        do {
            let items = try await archives.randomArchives(profile: profile, kind: kind)
                .sorted(by: MainPageCarouselMetadataHelpers.compareByDateDescending(_:_:))
            if Task.isCancelled {
                return
            }
            setState(kind, items: items, errorText: nil, isLoading: false)
        } catch {
            if Task.isCancelled || ErrorPresenter.isCancellationLike(error) {
                return
            }
            setState(kind, items: [], errorText: ErrorPresenter.short(error), isLoading: false)
        }
    }

    private func setLoading(_ kind: MainPageCarouselKind, _ loading: Bool) {
        switch kind {
        case .newArchives:
            newArchives.isLoading = loading
            newArchives.errorText = nil
        case .untaggedArchives:
            untaggedArchives.isLoading = loading
            untaggedArchives.errorText = nil
        }
    }

    private func setState(_ kind: MainPageCarouselKind, items: [ArchiveMetadata], errorText: String?, isLoading: Bool) {
        switch kind {
        case .newArchives:
            newArchives.items = items
            newArchives.errorText = errorText
            newArchives.isLoading = isLoading
        case .untaggedArchives:
            untaggedArchives.items = items
            untaggedArchives.errorText = errorText
            untaggedArchives.isLoading = isLoading
        }
    }
}

private struct MainPageCarouselSection: View {
    @EnvironmentObject private var appModel: AppModel

    let kind: MainPageCarouselKind
    let state: MainPageCarouselsViewModel.CarouselState
    let profile: Profile
    let onRefresh: () -> Void
    let onEditMetadata: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if state.isLoading {
                    ProgressView()
                        .scaleEffect(0.75)
                }
            }

            if let errorText = state.errorText {
                Text("Unavailable: \(errorText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state.items.isEmpty {
                Text(state.isLoading ? "Loading…" : "No archives returned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(state.items, id: \.arcid) { meta in
                            MainPageCarouselCard(profile: profile, metadata: meta, onEditMetadata: onEditMetadata)
                                .environmentObject(appModel)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct MainPageCarouselCard: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    let profile: Profile
    let metadata: ArchiveMetadata
    let onEditMetadata: (String) -> Void

    @State private var showDetails: Bool = false
    @State private var hoveringCover: Bool = false
    @State private var hoveringPopover: Bool = false
    @State private var hoveringSelectionControl: Bool = false
    @State private var popoverOpenTask: Task<Void, Never>?
    @State private var popoverCloseTask: Task<Void, Never>?

    private static let hoverOpenDelayNs: UInt64 = 140_000_000
    private static let hoverCloseDelayNs: UInt64 = 200_000_000

    private var title: String {
        let t = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "Untitled" : t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                CoverThumb(
                    profile: profile,
                    arcid: metadata.arcid,
                    thumbnails: appModel.thumbnails,
                    size: .init(width: 160, height: 228),
                    contentInset: 8,
                    showsBorder: false
                )
                .overlay(alignment: .topLeading) {
                    if metadata.isnew == true {
                        CoverBadge(text: "NEW", background: .green.opacity(0.55), font: .caption2.weight(.bold))
                            .padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if hoveringCover || hoveringSelectionControl || appModel.selection.contains(metadata.arcid) {
                        Button {
                            appModel.selection.toggle(metadata.arcid)
                        } label: {
                            Image(systemName: appModel.selection.contains(metadata.arcid) ? "checkmark.circle.fill" : "circle")
                                .imageScale(.large)
                                .foregroundStyle(appModel.selection.contains(metadata.arcid) ? .green : .white)
                                .padding(8)
                                .background(.black.opacity(0.22))
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        }
                        .buttonStyle(.plain)
                        .help("Select for batch operations")
                        .onHover { hovering in
                            hoveringSelectionControl = hovering
                        }
                        .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let d = MainPageCarouselMetadataHelpers.dateAdded(metadata) {
                        CoverBadge(text: Self.dateFormatter.string(from: d), font: .caption2.monospacedDigit().weight(.bold))
                            .padding(8)
                    }
                }
                .onHover { hovering in
                    hoveringCover = hovering
                    updatePopoverVisibility()
                }
                .popover(isPresented: $showDetails) {
                    ArchiveHoverDetailsView(
                        title: metadata.title ?? title,
                        summary: metadata.summary ?? "",
                        tags: metadata.tags ?? "",
                        pageCount: metadata.pagecount ?? 0,
                        onSelectTag: { rawTag in
                            appModel.requestLibrarySearch(profileID: profile.id, query: rawTag)
                            showDetails = false
                        }
                    )
                    .onHover { hovering in
                        hoveringPopover = hovering
                        updatePopoverVisibility()
                    }
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .init(x: 0.5, y: 0.45),
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if let line = archiveLine, !line.isEmpty {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .allowsHitTesting(false)
            }
            .frame(width: 160, height: 228)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(hoveringCover ? 0.36 : 0.24), radius: hoveringCover ? 12 : 6, x: 0, y: hoveringCover ? 6 : 3)
            .scaleEffect(hoveringCover ? 1.03 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.78), value: hoveringCover)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                openReader()
            }
            .help("Open reader")
            .contextMenu {
                Button("Open Reader") {
                    openReader()
                }
                Button("Open in Browser") {
                    openArchiveInBrowser()
                }
                Button("Edit Metadata…") {
                    onEditMetadata(metadata.arcid)
                }
                Divider()
                Button("Copy Archive ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(metadata.arcid, forType: .string)
                }
            }

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)

            if let line = archiveLine, !line.isEmpty {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(width: 160)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    private var archiveLine: String? {
        let tags = metadata.tags ?? ""
        guard !tags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let artists = TagParsing.values(in: tags, namespace: "artist")
        let groups = TagParsing.values(in: tags, namespace: "group")
        var parts: [String] = []
        if !artists.isEmpty {
            parts.append(artists.joined(separator: ", "))
        }
        if !groups.isEmpty {
            parts.append(groups.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func openReader() {
        appModel.setActiveReader(profileID: profile.id, arcid: metadata.arcid)
        openWindow(id: "reader")
    }

    private func openArchiveInBrowser() {
        guard var comps = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false) else { return }
        comps.path = "/reader"
        comps.queryItems = [URLQueryItem(name: "id", value: metadata.arcid)]
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func updatePopoverVisibility() {
        popoverOpenTask?.cancel()
        popoverCloseTask?.cancel()

        if hoveringCover {
            showDetails = true
            popoverOpenTask = Task {
                try? await Task.sleep(nanoseconds: Self.hoverOpenDelayNs)
                if Task.isCancelled { return }
                await MainActor.run {
                    if hoveringCover {
                        showDetails = true
                    }
                }
            }
            return
        }

        if hoveringPopover {
            showDetails = true
            return
        }

        popoverCloseTask = Task {
            try? await Task.sleep(nanoseconds: Self.hoverCloseDelayNs)
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

private enum MainPageCarouselMetadataHelpers {
    static func dateAdded(_ meta: ArchiveMetadata) -> Date? {
        if let d = meta.dateAdded {
            return d
        }
        guard let tags = meta.tags else { return nil }
        return TagParsing.parseDateAddedTag(tags)
    }

    static func compareByDateDescending(_ lhs: ArchiveMetadata, _ rhs: ArchiveMetadata) -> Bool {
        let leftDate = dateAdded(lhs)
        let rightDate = dateAdded(rhs)

        switch (leftDate, rightDate) {
        case let (l?, r?):
            if l != r {
                return l > r
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        let leftTitle = lhs.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rightTitle = rhs.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if leftTitle != rightTitle {
            return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
        }
        return lhs.arcid.localizedCaseInsensitiveCompare(rhs.arcid) == .orderedAscending
    }

}

