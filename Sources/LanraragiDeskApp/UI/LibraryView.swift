import Foundation
import AppKit
import SwiftUI
import LanraragiKit

@MainActor
final class LibrarySearchFieldControl: ObservableObject {
    private weak var textField: NSTextField?

    func attach(_ textField: NSTextField) {
        self.textField = textField
    }

    func detach(_ textField: NSTextField) {
        if self.textField === textField {
            self.textField = nil
        }
    }

    func currentText(fallback: String) -> String {
        textField?.stringValue ?? fallback
    }

    func resignFocus() {
        guard let textField, textField.currentEditor() != nil else { return }
        _ = textField.window?.makeFirstResponder(nil)
    }
}

struct TankoubonReadOwnership {
    struct Token: Equatable {
        fileprivate let id: UUID
        let tankID: String
    }

    private var current: Token?

    mutating func begin(tankID rawTankID: String) -> Token? {
        let tankID = rawTankID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tankID.isEmpty else { return nil }
        if current?.tankID == tankID { return nil }
        let token = Token(id: UUID(), tankID: tankID)
        current = token
        return token
    }

    func isCurrent(_ token: Token) -> Bool {
        current == token
    }

    @discardableResult
    mutating func finishIfCurrent(_ token: Token) -> Bool {
        guard current == token else { return false }
        current = nil
        return true
    }

    mutating func invalidate() {
        current = nil
    }
}

struct LibrarySearchTextField: NSViewRepresentable {
    @Binding var text: String
    let control: LibrarySearchFieldControl
    let onSubmit: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, control: control, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(string: text)
        textField.placeholderString = "Search…"
        textField.isBezeled = true
        textField.bezelStyle = .roundedBezel
        textField.drawsBackground = true
        textField.isEditable = true
        textField.isSelectable = true
        textField.usesSingleLineMode = true
        textField.lineBreakMode = .byTruncatingTail
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submit(_:))
        textField.setAccessibilityIdentifier("library.search")
        control.attach(textField)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        control.attach(textField)
        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    static func dismantleNSView(_ textField: NSTextField, coordinator: Coordinator) {
        textField.delegate = nil
        textField.target = nil
        textField.action = nil
        coordinator.control?.detach(textField)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: @MainActor (String) -> Void
        weak var control: LibrarySearchFieldControl?

        init(
            text: Binding<String>,
            control: LibrarySearchFieldControl,
            onSubmit: @escaping @MainActor (String) -> Void
        ) {
            self.text = text
            self.control = control
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let textField = control as? NSTextField else {
                return false
            }

            // NSTextField's target/action is not consistently dispatched for Return
            // when hosted through NSViewRepresentable. Consume the field editor command
            // and commit its live value directly so an in-flight prior search cannot win.
            submit(textView.string, through: textField)
            return true
        }

        @objc func submit(_ sender: NSTextField) {
            let liveText = (sender.currentEditor() as? NSTextView)?.string ?? sender.stringValue
            submit(liveText, through: sender)
        }

        private func submit(_ liveText: String, through textField: NSTextField) {
            textField.stringValue = liveText
            text.wrappedValue = liveText
            onSubmit(liveText)
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    let profile: Profile

    @AppStorage("thumbs.cropToFill") private var cropThumbsToFill: Bool = false

    @StateObject private var vm = LibraryViewModel()
    @StateObject private var searchFieldControl = LibrarySearchFieldControl()
    @State private var filtersExpanded: Bool = false
    @State private var requestTimingsExpanded: Bool = false
    @State private var queryDraft: String = ""
    @State private var tagSuggestions: [TagSuggestionStore.Suggestion] = []
    @State private var tagSuggestionStatusText: String?
    @State private var tagSuggestionsLoading: Bool = false
    @State private var suggestionTask: Task<Void, Never>?
    @State private var editingMeta: EditorRoute?
    @State private var tankPicker: TankPickerRoute?
    @State private var tankEditor: TankEditorRoute?
    @State private var tankoubonReadTask: Task<Void, Never>?
    @State private var tankoubonReadOwnership = TankoubonReadOwnership()
    @State private var hoveringArchiveResultsArea: Bool = false

    // Used by list/table view to avoid refetching metadata per-cell.
    @State private var metaByArcid: [String: ArchiveMetadata] = [:]
    @State private var metadataEpoch: Int = 0
    @State private var listRowsCache = LibraryListRowsCache()
    @State private var listSortOrder: [KeyPathComparator<LibraryListRow>] = [
        .init(\.dateAddedSortKey, order: .reverse)
    ]

    struct EditorRoute: Identifiable, Hashable {
        let arcid: String
        var id: String { arcid }
    }

    struct TankPickerRoute: Identifiable, Hashable {
        let arcids: [String]
        var id: String { arcids.joined(separator: ",") }
    }

    struct TankEditorRoute: Identifiable, Hashable {
        let tankID: String
        var id: String { tankID }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            header

            if let banner = vm.bannerText {
                Text(banner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            MainPageCarouselsView(profile: profile)
                .environmentObject(appModel)

            if let err = vm.errorText {
                Text("Error: \(err)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            results
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $editingMeta) { route in
            ArchiveMetadataEditorView(
                profile: profile,
                arcid: route.arcid,
                initialMeta: nil,
                archives: appModel.archives,
                onSaved: { updated in
                    storeListMetadata(updated, for: route.arcid)
                    metadataEpoch &+= 1
                },
                onDelete: { arcid in
                    do {
                        try await appModel.archives.deleteArchive(profile: profile, arcid: arcid)
                        await appModel.thumbnails.invalidate(profile: profile, arcid: arcid)
                        appModel.selection.remove(arcid)
                        metaByArcid[arcid] = nil
                        listRowsCache.removeRow(for: arcid)
                        refreshLibrary(excluding: arcid)
                        appModel.activity.add(.init(kind: .action, title: "Deleted archive", detail: arcid))
                    } catch {
                        appModel.activity.add(.init(kind: .error, title: "Delete archive failed", detail: "\(arcid)\n\(error)"))
                        throw error
                    }
                },
                onRequestTiming: { operation, duration, outcome in
                    vm.recordTiming(operation: operation, duration: duration, outcome: outcome)
                }
            )
            .environmentObject(appModel)
        }
        .sheet(item: $tankPicker) { route in
            TankoubonPickerView(
                profile: profile,
                arcids: route.arcids,
                onAdded: { tankID in
                    // Open the editor right away so the new/updated tank can be reviewed.
                    tankEditor = TankEditorRoute(tankID: tankID)
                    refreshLibrary()
                }
            )
            .environmentObject(appModel)
        }
        .sheet(item: $tankEditor) { route in
            TankoubonEditorSheet(
                profile: profile,
                tankID: route.tankID,
                onChanged: { refreshLibrary() }
            )
            .environmentObject(appModel)
        }
        .onAppear {
            if queryDraft.isEmpty {
                queryDraft = vm.query
            }
            if vm.arcids.isEmpty {
                refreshLibrary()
            }
            Task { await vm.loadCategories(profile: profile) }
            Task { await prewarmTagSuggestions() }
        }
        .onChange(of: vm.sort) { _, _ in
            refreshLibrary()
        }
        .onChange(of: vm.newOnly) { _, _ in
            refreshLibrary()
        }
        .onChange(of: vm.untaggedOnly) { _, _ in
            refreshLibrary()
        }
        .onChange(of: vm.categoryID) { _, _ in
            refreshLibrary()
        }
        .onChange(of: vm.groupTanks) { _, _ in
            refreshLibrary()
        }
        .onChange(of: vm.arcids, initial: true) { _, arcids in
            listRowsCache.rebuild(
                arcids: arcids,
                metadata: metaByArcid,
                sortOrder: listSortOrder
            )
        }
        .onReceive(appModel.$librarySearchRequest) { request in
            guard let request else { return }
            guard request.profileID == profile.id else { return }

            let normalized = normalizeLANraragiQuery(request.query)
            queryDraft = normalized
            vm.query = normalized
            refreshLibrary()
            searchFieldControl.resignFocus()
            tagSuggestions = []
            appModel.consumeLibrarySearchRequest(id: request.id)
        }
        .onDisappear {
            cancelPendingTankoubonRead()
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

                Toggle("Crop Covers", isOn: $cropThumbsToFill)
                    .toggleStyle(.checkbox)
                    .font(.callout)

                if vm.layout == .grid {
                    Picker("Sort", selection: $vm.sort) {
                        ForEach(LibraryViewModel.Sort.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .frame(width: 170)
                }

                Text("\(appModel.selection.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(vm.isLoadingAll ? "Selecting…" : "Select All Results") {
                    Task { await selectAllResults() }
                }
                .disabled(vm.isLoading || vm.isLoadingAll || vm.arcids.isEmpty)

                Button("Add to Tankoubon…") {
                    let ids = appModel.selection.arcids.filter { !LANraragiID.isTankoubon($0) }.sorted()
                    guard !ids.isEmpty else { return }
                    tankPicker = TankPickerRoute(arcids: ids)
                }
                .disabled(appModel.selection.count == 0)
                .help("Add the selected archives to a Tankoubon")

                Button("Clear Selection") {
                    appModel.selection.clear()
                }
                .disabled(appModel.selection.count == 0)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        LibrarySearchTextField(
                            text: $queryDraft,
                            control: searchFieldControl,
                            onSubmit: handleSearchSubmit
                        )
                        .frame(height: 24)
                        .accessibilityLabel("Search")
                        .onChange(of: queryDraft) { _, _ in queueSuggestionRefresh() }
                        .frame(maxWidth: .infinity)

                        Button("Search") {
                            handleSearchSubmit(searchFieldControl.currentText(fallback: queryDraft))
                        }

                        Button("Clear") {
                            queryDraft = ""
                            vm.query = ""
                            refreshLibrary()
                        }
                        .disabled(queryDraft.isEmpty)
                    }

                    tagSuggestionList

                    Text("Query tips: separate terms with commas, use `-tag` for negation, and wildcards like `artist:*mura*`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .zIndex(10)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        filtersExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: filtersExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Filters")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if filtersExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 16) {
                            Toggle("New only", isOn: $vm.newOnly)
                            Toggle("Untagged only", isOn: $vm.untaggedOnly)
                            Toggle("Group Tankoubons", isOn: $vm.groupTanks)
                                .help("Show Tankoubons in results instead of their member archives (requires a server with Tankoubon support)")
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            pinnedCategoryButtons

                            Menu {
                                Button("All categories") { vm.categoryID = "" }

                                let unpinned = vm.categories.filter { !$0.pinned }
                                if !unpinned.isEmpty {
                                    Divider()
                                }

                                ForEach(unpinned, id: \.id) { c in
                                    Button(c.name) { vm.categoryID = c.id }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder")
                                    Text(unpinnedCategoryLabel)
                                }
                                .font(.callout)
                            }
                            .menuStyle(.borderlessButton)

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
                    .padding(.top, 4)
                }
            }

            DisclosureGroup(isExpanded: $requestTimingsExpanded) {
                requestTimingDetails
                    .padding(.top, 4)
            } label: {
                HStack(spacing: 8) {
                    Text("Request timings")
                        .font(.callout.weight(.semibold))
                    if let latest = vm.requestTimingHistory.entries.first {
                        Text("Latest: \(latest.operation.title) · \(LibraryRequestTimingFormatter.duration(latest.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .center)
        .debugFrameNumber(1)
    }

    @ViewBuilder
    private var requestTimingDetails: some View {
        if vm.requestTimingHistory.entries.isEmpty {
            Text("Timings appear after Library searches, page fetches, and metadata refreshes or updates.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(vm.requestTimingHistory.entries) { timing in
                    HStack(spacing: 8) {
                        Image(systemName: timingOutcomeSymbol(timing.outcome))
                            .foregroundStyle(timingOutcomeColor(timing.outcome))
                            .frame(width: 14)
                        Text(timing.operation.title)
                            .frame(minWidth: 118, alignment: .leading)
                        Text(LibraryRequestTimingFormatter.duration(timing.duration))
                            .monospacedDigit()
                            .frame(minWidth: 62, alignment: .trailing)
                        Text(timing.outcome.title)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timing.completedAt, style: .time)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func timingOutcomeSymbol(_ outcome: LibraryRequestTimingOutcome) -> String {
        switch outcome {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        case .superseded: return "arrow.triangle.2.circlepath"
        }
    }

    private func timingOutcomeColor(_ outcome: LibraryRequestTimingOutcome) -> Color {
        switch outcome {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .superseded: return .orange
        }
    }

    private var tagSuggestionList: some View {
        let info = currentTokenInfo(queryDraft)
        let q = info.lookupPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let minChars = 1
        let eligible = q.count >= minChars

        // Always reserve space under the search field so suggestions are reliably visible.
        return GroupBox {
            if !eligible {
                Text("Start typing to see tag suggestions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else if tagSuggestionsLoading {
                Text("Loading suggestions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else if tagSuggestions.isEmpty {
                Text(tagSuggestionStatusText ?? "No suggestions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(tagSuggestions.prefix(24), id: \.value) { s in
                            Button {
                                applySuggestion(s.value)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(s.value)
                                        .font(.callout)
                                        .foregroundStyle(.primary)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Text("\(s.weight)")
                                        .font(.caption2.monospacedDigit())
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
                .scrollIndicators(.visible)
                .frame(maxHeight: 170)

                if let tagSuggestionStatusText, !tagSuggestionStatusText.isEmpty {
                    Text(tagSuggestionStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pinnedCategoryButtons: some View {
        let pinned = vm.categories.filter { $0.pinned }

        return FlowLayout(spacing: 8, lineSpacing: 8) {
            CategoryChip(title: "All", selected: vm.categoryID.isEmpty) {
                vm.categoryID = ""
            }
            ForEach(pinned, id: \.id) { c in
                CategoryChip(title: c.name, selected: vm.categoryID == c.id, pinned: true) {
                    vm.categoryID = c.id
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unpinnedCategoryLabel: String {
        guard !vm.categoryID.isEmpty else { return "More categories" }
        if let c = vm.categories.first(where: { $0.id == vm.categoryID }), !c.pinned {
            return c.name
        }
        return "More categories"
    }

    private func addTagToQuery(_ rawTag: String) {
        let t = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        // Insert the raw tag token (ex: "female:ahegao" or "vanilla") without adding "tag:".
        let token = t
        let needsComma = !queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(",")
        queryDraft = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            + (needsComma ? ", " : "")
            + token
            + ", "
    }

    private func openArchiveInBrowser(_ arcid: String) {
        let trimmed = arcid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var comps = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false) else { return }
        comps.path = "/reader"
        comps.queryItems = [URLQueryItem(name: "id", value: trimmed)]
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }

    private func openReader(_ arcid: String) {
        if LANraragiID.isTankoubon(arcid) {
            readTankoubon(arcid)
            return
        }
        cancelPendingTankoubonRead()
        appModel.setActiveReader(profileID: profile.id, arcid: arcid)
        openWindow(id: "reader")
    }

    private func readTankoubon(_ tankID: String) {
        guard let request = tankoubonReadOwnership.begin(tankID: tankID) else { return }
        tankoubonReadTask?.cancel()
        let activeRouteAtStart = appModel.activeReaderRoute

        tankoubonReadTask = Task {
            defer {
                if tankoubonReadOwnership.finishIfCurrent(request) {
                    tankoubonReadTask = nil
                }
            }
            do {
                let tank = try await appModel.archives.tankoubonWithArchiveMetadata(
                    profile: profile,
                    tankID: request.tankID
                )
                guard !Task.isCancelled,
                      tankoubonReadOwnership.isCurrent(request),
                      appModel.activeReaderRoute == activeRouteAtStart else { return }
                let context = TankoubonReaderContext(tankoubon: tank)
                guard let route = context.readerRoute(profileID: profile.id) else {
                    tankEditor = TankEditorRoute(tankID: request.tankID)
                    return
                }
                appModel.setActiveReader(route)
                openWindow(id: "reader")
            } catch {
                guard !Task.isCancelled,
                      tankoubonReadOwnership.isCurrent(request) else { return }
                appModel.activity.add(.init(
                    kind: .error,
                    title: "Couldn’t open Tankoubon",
                    detail: "\(request.tankID)\n\(ErrorPresenter.short(error))",
                    component: "Tankoubons"
                ))
            }
        }
    }

    private func cancelPendingTankoubonRead() {
        tankoubonReadTask?.cancel()
        tankoubonReadTask = nil
        tankoubonReadOwnership.invalidate()
    }

    private func handleSearchSubmit(_ draft: String) {
        let normalized = normalizeLANraragiQuery(draft)
        queryDraft = normalized
        refreshLibrary(submittingQuery: normalized)
    }

    private func refreshLibrary(
        excluding excludedArcid: String? = nil,
        submittingQuery: String? = nil
    ) {
        metadataEpoch &+= 1
        metaByArcid.removeAll()
        let visibleArcids: [String]
        if let excludedArcid {
            visibleArcids = vm.arcids.filter { $0 != excludedArcid }
        } else {
            visibleArcids = vm.arcids
        }
        listRowsCache.rebuild(
            arcids: visibleArcids,
            metadata: metaByArcid,
            sortOrder: listSortOrder
        )
        if let submittingQuery {
            vm.submitSearch(query: submittingQuery, profile: profile)
        } else {
            vm.refresh(profile: profile)
        }
    }

    private func selectAllResults() async {
        let all = await vm.loadAll(profile: profile)
        appModel.selection.add(all)
        appModel.activity.add(.init(kind: .action, title: "Selected all results", detail: "\(all.count) archives"))
    }

    @ViewBuilder
    private var results: some View {
        switch vm.layout {
        case .grid:
            let spacing: CGFloat = 8
            let columns = [GridItem(
                .adaptive(minimum: LibraryCard.outerCardWidth, maximum: LibraryCard.outerCardWidth),
                spacing: spacing,
                alignment: .top
            )]

            ScrollView {
                LazyVGrid(
                    columns: columns,
                    alignment: .center,
                    spacing: spacing
                ) {
                    ForEach(vm.arcids, id: \.self) { arcid in
                        LibraryCard(
                            profile: profile,
                            arcid: arcid,
                            metadataEpoch: metadataEpoch,
                            allowHoverDetails: hoveringArchiveResultsArea,
                            onSelectTag: addTagToQuery,
                            onOpenReader: {
                                openReader(arcid)
                            }
                        )
                            .environmentObject(appModel)
                            .contextMenu {
                                if LANraragiID.isTankoubon(arcid) {
                                    Button("Read Tankoubon") {
                                        readTankoubon(arcid)
                                    }
                                    Button("Edit Tankoubon…") {
                                        tankEditor = TankEditorRoute(tankID: arcid)
                                    }
                                    Button("Open in Browser") {
                                        openArchiveInBrowser(arcid)
                                    }
                                    Divider()
                                    Button("Copy Tankoubon ID") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(arcid, forType: .string)
                                    }
                                } else {
                                    Button("Open Reader") {
                                        openReader(arcid)
                                    }
                                    Button("Open in Browser") {
                                        openArchiveInBrowser(arcid)
                                    }
                                    Button("Edit Metadata…") {
                                        editingMeta = EditorRoute(arcid: arcid)
                                    }
                                    Button("Add to Tankoubon…") {
                                        tankPicker = TankPickerRoute(arcids: [arcid])
                                    }
                                    Divider()
                                    Button("Copy Archive ID") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(arcid, forType: .string)
                                    }
                                }
                            }
                            .onAppear {
                                if arcid == vm.arcids.last {
                                    Task { await vm.loadMore(profile: profile) }
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, spacing)
                .padding(.top, 6)

                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(20)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                hoveringArchiveResultsArea = hovering
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .debugFrameNumber(2)

        case .list:
            libraryTable
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

    private var listSortBinding: Binding<[KeyPathComparator<LibraryListRow>]> {
        Binding(
            get: { listSortOrder },
            set: { newSortOrder in
                listSortOrder = newSortOrder
                listRowsCache.sort(using: newSortOrder)
            }
        )
    }

    private var libraryTable: some View {
        Table(listRowsCache.rows, sortOrder: listSortBinding) {
            TableColumn("Select") { row in
                if LANraragiID.isTankoubon(row.arcid) {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(.secondary)
                        .help("Tankoubon")
                } else {
                    Button {
                        appModel.selection.toggle(row.arcid)
                    } label: {
                        Image(systemName: appModel.selection.contains(row.arcid) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(appModel.selection.contains(row.arcid) ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Select for batch operations")
                }
            }
            .width(min: 54, ideal: 54, max: 54)

            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 10) {
                    CoverThumb(profile: profile, arcid: row.arcid, thumbnails: appModel.thumbnails, size: .init(width: 38, height: 52), showsBorder: false)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(row.title)
                        .font(.callout)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    openReader(row.arcid)
                }
                .task(id: "\(row.arcid)#\(metadataEpoch)") {
                    if metaByArcid[row.arcid] != nil { return }
                    do {
                        let meta = try await appModel.archives.metadata(profile: profile, arcid: row.arcid)
                        await MainActor.run {
                            storeListMetadata(meta, for: row.arcid)
                        }
                    } catch {
                        // Leave as-is; cover/title still show.
                    }
                }
                .onAppear {
                    if row.arcid == vm.arcids.last {
                        Task { await vm.loadMore(profile: profile) }
                    }
                }
                .contextMenu {
                    if LANraragiID.isTankoubon(row.arcid) {
                        Button("Read Tankoubon") {
                            readTankoubon(row.arcid)
                        }
                        Button("Edit Tankoubon…") {
                            tankEditor = TankEditorRoute(tankID: row.arcid)
                        }
                        Button("Open in Browser") {
                            openArchiveInBrowser(row.arcid)
                        }
                        Divider()
                        Button("Copy Tankoubon ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.arcid, forType: .string)
                        }
                    } else {
                        Button("Open Reader") {
                            openReader(row.arcid)
                        }
                        Button("Open in Browser") {
                            openArchiveInBrowser(row.arcid)
                        }
                        Button("Edit Metadata…") {
                            editingMeta = EditorRoute(arcid: row.arcid)
                        }
                        Button("Add to Tankoubon…") {
                            tankPicker = TankPickerRoute(arcids: [row.arcid])
                        }
                        Divider()
                        Button("Copy Archive ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(row.arcid, forType: .string)
                        }
                    }
                }
            }

            TableColumn("New", value: \.isNewSortKey) { row in
                if row.isNew {
                    Text("NEW")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                } else {
                    Text("")
                }
            }
            .width(min: 52, ideal: 52, max: 70)

            TableColumn("Date", value: \.dateAddedSortKey) { row in
                Text(row.dateAddedText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 120, max: 160)

            TableColumn("Artist", value: \.artist) { row in
                Text(row.artist)
                    .font(.callout)
                    .foregroundStyle(row.artist.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Group", value: \.group) { row in
                Text(row.group)
                    .font(.callout)
                    .foregroundStyle(row.group.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Tags", value: \.tags) { row in
                Text(row.tags)
                    .font(.callout)
                    .foregroundStyle(row.tags.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 220, ideal: 380)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(.thinMaterial)
        .debugFrameNumber(2)
    }

    private func storeListMetadata(_ metadata: ArchiveMetadata, for arcid: String) {
        metaByArcid[arcid] = metadata
        listRowsCache.updateMetadata(
            metadata,
            for: arcid,
            sortOrder: listSortOrder
        )
    }

    private func refreshSuggestions() async {
        await MainActor.run {
            tagSuggestionsLoading = true
            tagSuggestionStatusText = nil
        }
        let info = currentTokenInfo(queryDraft)
        let q = info.lookupPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let minChars = 1
        guard q.count >= minChars else {
            await MainActor.run { tagSuggestions = [] }
            await MainActor.run { tagSuggestionsLoading = false }
            return
        }

        let minWeight = UserDefaults.standard.integer(forKey: "tags.minWeight")
        let ttlHours = max(1, UserDefaults.standard.integer(forKey: "tags.ttlHours"))
        let settings = TagSuggestionStore.Settings(minWeight: minWeight, ttlSeconds: ttlHours * 60 * 60)

        let sugg = await appModel.tagSuggestions.suggestions(profile: profile, settings: settings, prefix: q, limit: 20)
        let err = await appModel.tagSuggestions.lastError(profile: profile)
        await MainActor.run {
            tagSuggestions = sugg
            tagSuggestionStatusText = err
            tagSuggestionsLoading = false
        }
    }

    private func applySuggestion(_ value: String) {
        let info = currentTokenInfo(queryDraft)
        let trimmedRaw = info.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            queryDraft = value + ", "
            tagSuggestions = []
            return
        }

        let preservedTagPrefix = info.hasTagPrefix ? "tag:" : ""
        let token = (info.isNegated ? "-" : "") + preservedTagPrefix + value

        if let range = info.range {
            let head = String(queryDraft[..<range.lowerBound])
            queryDraft = head + token + ", "
        } else {
            queryDraft = token + ", "
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

    private func currentTokenInfo(_ query: String) -> TokenInfo {
        let q = query
        if q.isEmpty {
            return TokenInfo(raw: "", range: nil, isNegated: false, hasTagPrefix: false, lookupPrefix: "")
        }

        let separators = CharacterSet(charactersIn: ",;\n\r")
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

    private func prewarmTagSuggestions() async {
        let minWeight = UserDefaults.standard.integer(forKey: "tags.minWeight")
        let ttlHours = max(1, UserDefaults.standard.integer(forKey: "tags.ttlHours"))
        let settings = TagSuggestionStore.Settings(minWeight: minWeight, ttlSeconds: ttlHours * 60 * 60)
        await appModel.tagSuggestions.prewarm(profile: profile, settings: settings)
    }

    // LANraragi treats commas as token delimiters. Spaces are valid inside a token.
    // We normalize only explicit separators (; and newlines) to commas and trim comma spacing.
    private func normalizeLANraragiQuery(_ input: String) -> String {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        var buf = ""
        var inQuotes = false
        var parts: [String] = []
        parts.reserveCapacity(8)

        func flushBuf() {
            let piece = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            buf = ""
            guard !piece.isEmpty else { return }
            parts.append(piece)
        }

        for ch in s {
            if ch == "\"" {
                inQuotes.toggle()
                buf.append(ch)
                continue
            }
            if (ch == "," || ch == ";" || ch.isNewline), !inQuotes {
                flushBuf()
                continue
            }
            buf.append(ch)
        }
        flushBuf()

        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

// App-internal so the cache behavior can be covered through @testable import.
struct LibraryListRow: Identifiable, Hashable {
    let arcid: String
    let sourceIndex: Int

    let isNew: Bool
    let dateAdded: Date?
    let title: String
    let artist: String
    let group: String
    let tags: String

    var id: String { arcid }

    // Sort keys must be non-optional.
    var isNewSortKey: Int { isNew ? 1 : 0 }
    var dateAddedSortKey: Double { dateAdded?.timeIntervalSince1970 ?? 0 }

    var dateAddedText: String {
        guard let dateAdded else { return "" }
        return Self.dateFormatter.string(from: dateAdded)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    init(arcid: String, sourceIndex: Int, meta: ArchiveMetadata?) {
        self.arcid = arcid
        self.sourceIndex = sourceIndex

        let t = meta?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = t.isEmpty ? "Untitled" : t
        self.tags = (meta?.tags ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        self.isNew = meta?.isnew ?? false
        self.dateAdded = ArchiveMetaHelpers.dateAdded(meta)

        self.artist = ArchiveMetaHelpers.artists(meta).joined(separator: ", ")
        self.group = ArchiveMetaHelpers.groups(meta).joined(separator: ", ")
    }
}

private struct LibraryCard: View {
    static let outerCardWidth: CGFloat = 196
    private static let outerCardHeight: CGFloat = 300
    private static let coverSize: CGSize = .init(width: 196, height: 300)

    @EnvironmentObject private var appModel: AppModel

    let profile: Profile
    let arcid: String
    let metadataEpoch: Int
    var allowHoverDetails: Bool = true
    let onSelectTag: (String) -> Void
    let onOpenReader: () -> Void

    @State private var meta: ArchiveMetadata?
    @State private var title: String = "Loading…"
    @State private var showDetails: Bool = false
    @State private var hoveringCover: Bool = false
    @State private var hoveringPopover: Bool = false
    @State private var hoveringSelectionControl: Bool = false
    @State private var popoverOpenTask: Task<Void, Never>?
    @State private var popoverCloseTask: Task<Void, Never>?
    private static let hoverOpenDelayNs: UInt64 = 140_000_000
    private static let hoverCloseDelayNs: UInt64 = 200_000_000

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func openReaderFromCard() {
        showDetails = false
        onOpenReader()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CoverThumb(profile: profile, arcid: arcid, thumbnails: appModel.thumbnails, size: Self.coverSize, showsBorder: false)
                .overlay(alignment: .topLeading) {
                    if LANraragiID.isTankoubon(arcid) {
                        CoverBadge(text: "TANK", background: .blue.opacity(0.6))
                            .padding(8)
                    } else if meta?.isnew == true {
                        CoverBadge(text: "NEW", background: .green.opacity(0.55))
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let d = ArchiveMetaHelpers.dateAdded(meta) {
                        CoverBadge(text: Self.dateFormatter.string(from: d))
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
                        tags: meta?.tags ?? "",
                        pageCount: meta?.pagecount ?? 0,
                        onSelectTag: { rawTag in
                            onSelectTag(rawTag)
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

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(nil)
                let artistLine = ArchiveMetaHelpers.artists(meta).joined(separator: ", ")
                let groupLine = ArchiveMetaHelpers.groups(meta).joined(separator: ", ")
                let secondaryLine: String? = artistLine.isEmpty ? (groupLine.isEmpty ? nil : groupLine) : artistLine
                if let secondaryLine {
                    Text(secondaryLine)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .allowsHitTesting(false)
        }
        .frame(width: Self.outerCardWidth, height: Self.outerCardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            // Tanks aren't valid batch-operation targets, so they can't be selected.
            if !LANraragiID.isTankoubon(arcid),
               hoveringCover || hoveringSelectionControl || appModel.selection.contains(arcid) {
                // Keep selection as a separate button so the cover's single-click open stays reliable.
                Button {
                    appModel.selection.toggle(arcid)
                } label: {
                    Image(systemName: appModel.selection.contains(arcid) ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .foregroundStyle(appModel.selection.contains(arcid) ? .green : .white)
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
                .padding(16)
            }
        }
        .shadow(color: .black.opacity(hoveringCover ? 0.42 : 0.28), radius: hoveringCover ? 18 : 8, x: 0, y: hoveringCover ? 8 : 4)
        .scaleEffect(hoveringCover ? 1.04 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hoveringCover)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            openReaderFromCard()
        }
        .help("Open reader")
        .task(id: "\(arcid)#\(metadataEpoch)") {
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
        popoverOpenTask?.cancel()
        popoverCloseTask?.cancel()

        if hoveringCover {
            guard allowHoverDetails else {
                showDetails = false
                return
            }
            // Intent delay prevents accidental retargeting when cursor passes over
            // narrow popover-arrow gaps between nearby covers.
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

        // Give the cursor time to move from the cover to the popover without it collapsing immediately.
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
            // Faux-stroke for readability on busy thumbnails.
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


private struct CategoryChip: View {
    let title: String
    let selected: Bool
    var pinned: Bool = false
    let onClick: () -> Void

    var body: some View {
        let bg: AnyShapeStyle = selected
            ? AnyShapeStyle(Color.accentColor.opacity(0.25))
            : AnyShapeStyle(.quaternary.opacity(0.35))

        Button {
            onClick()
        } label: {
            HStack(spacing: 6) {
                if pinned {
                    Image(systemName: "pin.fill")
                        .imageScale(.small)
                }
                Text(title)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(bg)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor).opacity(0.45),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

private enum ArchiveMetaHelpers {
    static func dateAdded(_ meta: ArchiveMetadata?) -> Date? {
        guard let meta else { return nil }
        if let d = meta.dateAdded { return d }
        guard let tags = meta.tags else { return nil }
        return TagParsing.parseDateAddedTag(tags)
    }

    static func artists(_ meta: ArchiveMetadata?) -> [String] {
        guard let tags = meta?.tags else { return [] }
        return TagParsing.values(in: tags, namespace: "artist")
    }

    static func groups(_ meta: ArchiveMetadata?) -> [String] {
        guard let tags = meta?.tags else { return [] }
        return TagParsing.values(in: tags, namespace: "group")
    }

    static func artistGroupLine(_ meta: ArchiveMetadata?) -> String? {
        guard let tags = meta?.tags else { return nil }
        let artists = TagParsing.values(in: tags, namespace: "artist")
        let groups = TagParsing.values(in: tags, namespace: "group")

        var parts: [String] = []
        if !artists.isEmpty {
            parts.append("Artist: " + artists.joined(separator: ", "))
        }
        if !groups.isEmpty {
            parts.append("Group: " + groups.joined(separator: ", "))
        }
        return parts.joined(separator: "  •  ")
    }
}
