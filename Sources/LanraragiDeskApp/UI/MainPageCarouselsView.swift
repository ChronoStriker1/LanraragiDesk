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
                    MainPageCarouselHoverDetailsView(
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

        let artists = Self.values(in: tags, namespace: "artist")
        let groups = Self.values(in: tags, namespace: "group")
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

    private static func values(in tags: String, namespace: String) -> [String] {
        let ns = namespace.lowercased()
        var out: [String] = []
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

        var seen: Set<String> = []
        var uniq: [String] = []
        for value in out where seen.insert(value.lowercased()).inserted {
            uniq.append(value)
        }
        return uniq
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

    static func dateAdded(_ meta: ArchiveMetadata) -> Date? {
        if let d = meta.dateAdded {
            return d
        }
        guard let tags = meta.tags else { return nil }
        return parseDateAddedTag(tags)
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

    private static func parseDateAddedTag(_ tags: String) -> Date? {
        for raw in tags.split(separator: ",") {
            let tok = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let idx = tok.firstIndex(of: ":") else { continue }
            let lhs = tok[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard lhs == "date_added" || lhs == "dateadded" || lhs == "date" else { continue }

            let value = tok[tok.index(after: idx)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

            for formatter in dateOnlyParsers where formatter.date(from: value) != nil {
                return formatter.date(from: value)
            }
        }

        return nil
    }
}

private struct MainPageCarouselHoverDetailsView: View {
    let title: String
    let summary: String
    let tags: String
    let pageCount: Int
    let onSelectTag: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(title.isEmpty ? "Untitled" : title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if pageCount > 0 {
                    Text("\(pageCount) pp")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(Capsule())
                        .fixedSize()
                }
            }

            let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSummary.isEmpty {
                Divider()
                Text(trimmedSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            let trimmedTags = tags.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTags.isEmpty {
                Divider()
                MainPageCarouselHoverTagCloud(tags: trimmedTags, onSelectTag: onSelectTag)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

private struct MainPageCarouselHoverTagCloud: View {
    let tags: String
    let onSelectTag: (String) -> Void

    private struct TagItem {
        var display: String
        var token: String
    }

    private static let humanDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var groups: [(namespace: String, items: [TagItem])] {
        let parsed: [TagItem] = tags
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { tok in
                let (ns, v) = MainPageCarouselTagParser.splitNamespace(tok)
                let display: String
                if MainPageCarouselTagParser.isDateNamespace(ns), let d = MainPageCarouselTagParser.parseDateValue(v) {
                    display = "\(ns):\(Self.humanDateFormatter.string(from: d))"
                } else {
                    display = tok
                }
                return TagItem(display: display, token: tok)
            }

        let bucket = Dictionary(grouping: parsed) { item -> String in
            let (ns, _) = MainPageCarouselTagParser.splitNamespace(item.token)
            return ns.isEmpty ? "tag" : ns.lowercased()
        }
        let keys = bucket.keys.sorted { a, b in
            if a == "tag", b != "tag" { return true }
            if a != "tag", b == "tag" { return false }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return keys.compactMap { k in
            guard let items = bucket[k] else { return nil }
            let sorted = items.sorted { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
            return (namespace: k, items: sorted)
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(groups, id: \.namespace) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.namespace == "tag" ? "Tags" : group.namespace)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        MainPageCarouselTagPillFlow(spacing: 4) {
                            ForEach(group.items, id: \.token) { tag in
                                Text(tag.display)
                                    .font(.caption2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.quaternary.opacity(0.6))
                                    .clipShape(Capsule())
                                    .contentShape(Capsule())
                                    .onTapGesture { onSelectTag(tag.token) }
                                    .help("Search: \(tag.display)")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.visible)
        .frame(maxHeight: 220)
    }
}

/// A simple wrapping flow layout. Lays children left-to-right, wrapping to a
/// new row when the next child would exceed the available width.
private struct MainPageCarouselTagPillFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).totalSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        for (subview, origin) in zip(subviews, result.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        var origins: [CGPoint]
        var totalSize: CGSize
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return LayoutResult(
            origins: origins,
            totalSize: CGSize(width: maxWidth, height: y + rowHeight)
        )
    }
}

private enum MainPageCarouselTagParser {
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
