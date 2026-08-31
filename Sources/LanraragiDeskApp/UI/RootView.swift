import AppKit
import SwiftUI
import LanraragiKit

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var showNotMatchesPanel: Bool = false
    @State private var showClearNotMatchesConfirmation: Bool = false
    @State private var advancedExpanded: Bool = false
    @State private var section: Section = .library
    @State private var activatedSections: Set<Section> = [.library]
    @State private var sidebarVisible: Bool = true
    @AppStorage("sidebar.showStatistics") private var showStatisticsPage: Bool = false

    enum Section: Hashable {
        case library
        case statistics
        case duplicates
        case settings
        case activity
        case batch
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .windowBackgroundColor).opacity(0.85),
                    Color(nsColor: .controlBackgroundColor).opacity(0.8),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            content
        }
        .onAppear {
            appModel.selectFirstIfNeeded()
            if appModel.selectedProfile == nil {
                appModel.profileEditorMode = .add
            }
        }
        .onChange(of: showStatisticsPage) { _, enabled in
            if !enabled, section == .statistics {
                section = .library
            }
        }
        .onChange(of: section) { _, activeSection in
            activatedSections.insert(activeSection)
        }
        .onReceive(appModel.$librarySearchRequest) { request in
            guard let request else { return }
            guard request.profileID == appModel.selectedProfileID else { return }
            section = .library
        }
        .sheet(item: $appModel.profileEditorMode) { mode in
            ProfileEditorView(mode: mode)
        }
        .onChange(of: appModel.duplicates.resultRevision) { _, _ in
            // Keep users on the Duplicates workspace when results are ready.
            if case .completed = appModel.duplicates.status, appModel.duplicates.result != nil {
                section = .duplicates
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        sidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: sidebarVisible ? "sidebar.left" : "sidebar.right")
                }
                .buttonStyle(.plain)
                .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityLabel(sidebarVisible ? Text("Hide Sidebar") : Text("Show Sidebar"))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let profile = appModel.selectedProfile {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        sidebar
                            .frame(width: 240)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    detail(profile: profile)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 980, minHeight: 640)
            .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
        } else {
            ContentUnavailableView(
                "Connect To LANraragi",
                systemImage: "server.rack",
                description: Text("Set your server address and API key to start finding duplicates.")
            )
            .emptyStatePanel()
            .padding(24)
            .frame(minWidth: 700, minHeight: 520)
        }
    }

    private var sidebar: some View {
        ZStack {
            // Finder-like frosted background that respects system reduced-transparency settings.
            SidebarVibrancy()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarSectionHeader("Browse", topPadding: 0)
                    sidebarButton(title: "Library", systemImage: "books.vertical", section: .library)
                    if showStatisticsPage {
                        sidebarButton(title: "Statistics", systemImage: "chart.bar.xaxis", section: .statistics)
                    }

                    sidebarSectionHeader("Tools")
                    sidebarButton(title: "Duplicates", systemImage: "doc.on.doc", section: .duplicates)
                    sidebarButton(title: "Activity", systemImage: "list.bullet.rectangle", section: .activity)
                    sidebarButton(title: "Batch", systemImage: "square.stack.3d.forward.dottedline", section: .batch)

                    sidebarSectionHeader("App")
                    sidebarButton(title: "Settings", systemImage: "gearshape", section: .settings)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Sections"))
    }

    private func sidebarSectionHeader(_ title: String, topPadding: CGFloat = 14) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, topPadding)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func sidebarButton(title: String, systemImage: String, section target: Section) -> some View {
        let isSelected = section == target
        return Button {
            section = target
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(SidebarNavButtonStyle(isSelected: isSelected))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func detail(profile: Profile) -> some View {
        ZStack {
            LibraryView(profile: profile)
                .environmentObject(appModel)
                .opacity(section == .library ? 1 : 0)
                .allowsHitTesting(section == .library)
                .accessibilityHidden(section != .library)

            if showStatisticsPage, shouldMount(.statistics) {
                StatisticsView(profile: profile)
                    .environmentObject(appModel)
                    .opacity(section == .statistics ? 1 : 0)
                    .allowsHitTesting(section == .statistics)
                    .accessibilityHidden(section != .statistics)
            }

            duplicatesWorkspace(profile: profile)
                .opacity(section == .duplicates ? 1 : 0)
                .allowsHitTesting(section == .duplicates)
                .accessibilityHidden(section != .duplicates)

            ActivityView()
                .environmentObject(appModel)
                .opacity(section == .activity ? 1 : 0)
                .allowsHitTesting(section == .activity)
                .accessibilityHidden(section != .activity)

            if shouldMount(.batch) {
                BatchView()
                    .environmentObject(appModel)
                    .opacity(section == .batch ? 1 : 0)
                    .allowsHitTesting(section == .batch)
                    .accessibilityHidden(section != .batch)
            }

            SettingsView()
                .environmentObject(appModel)
                .opacity(section == .settings ? 1 : 0)
                .allowsHitTesting(section == .settings)
                .accessibilityHidden(section != .settings)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .clipped()
    }

    private func shouldMount(_ target: Section) -> Bool {
        section == target || activatedSections.contains(target)
    }

    @ViewBuilder
    private func duplicatesWorkspace(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            runCard(profile: profile)

            if appModel.duplicates.result != nil {
                reviewTab(profile: profile)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                noResultsPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var noResultsPlaceholder: some View {
        ContentUnavailableView(
            "No Results Yet",
            systemImage: "square.stack.3d.up.slash",
            description: Text("Run a scan to see duplicate groups here.")
        )
        .emptyStatePanel()
    }

    @ViewBuilder
    private func reviewTab(profile: Profile) -> some View {
        if let result = appModel.duplicates.result {
            PairReviewView(
                profile: profile,
                result: result,
                thumbnails: appModel.duplicates.thumbnails,
                archives: appModel.duplicates.archives,
                markNotDuplicate: { pair in
                    appModel.duplicates.markNotDuplicate(profile: profile, pair: pair)
                },
                deleteArchive: { arcid in
                    try await appModel.duplicates.deleteArchive(profile: profile, arcid: arcid)
                }
            )
        } else {
            noResultsPlaceholder
        }
    }

    private func runCard(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find Duplicate Archives")
                        .font(.headline)

                    Text("Click Find Duplicates. The app will update its local index if needed, then show you likely duplicates to review and delete manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                Button {
                    section = .duplicates
                    appModel.duplicates.start(profile: profile)
                } label: {
                    Label("Find Duplicates", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDuplicateScanRunning)

                Button("Cancel", role: .destructive) {
                    appModel.duplicates.cancel()
                }
                .buttonStyle(.bordered)
                .disabled(!isDuplicateScanRunning)
            }

            HStack(alignment: .top, spacing: 12) {
                statusBlock(profile: profile)

                Spacer(minLength: 12)

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        advancedExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: advancedExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                        Text("Advanced")
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(advancedExpanded ? "Hide Advanced Options" : "Show Advanced Options")
            }

            if advancedExpanded {
                Divider()
                advancedOptions(profile: profile)
            }
        }
        .cardSurface(padding: 14)
        .debugFrameNumber(1)
        .sheet(isPresented: $showNotMatchesPanel) {
            NotMatchesView(profile: profile)
                .environmentObject(appModel)
                .frame(minWidth: 760, minHeight: 520)
                .padding(18)
        }
    }

    private var isDuplicateScanRunning: Bool {
        if case .running = appModel.duplicates.status {
            return true
        }
        return false
    }

    @ViewBuilder
    private func statusBlock(profile: Profile) -> some View {
        switch appModel.duplicates.status {
        case .idle:
            Text("Ready.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .running(let msg):
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .completed(let stats):
            VStack(alignment: .leading, spacing: 6) {
                Text("Found \(appModel.duplicates.result?.groups.count ?? 0) duplicate groups.")
                    .font(.callout.weight(.medium))
                Text("Scanned \(stats.archives) archives in \(String(format: "%.1fs", stats.durationSeconds)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if stats.excludedSameTankoubon > 0 {
                    Text("Ignored \(stats.excludedSameTankoubon) candidate \(stats.excludedSameTankoubon == 1 ? "pair" : "pairs") from the same Tankoubon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 8) {
                Label("Duplicate scan failed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button("Retry") {
                        appModel.duplicates.start(profile: profile)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Copy Error") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(msg, forType: .string)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func advancedOptions(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Match Strictness")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Strictness", selection: $appModel.duplicates.strictness) {
                Text("Strict").tag(DuplicateScanViewModel.Strictness.strict)
                Text("Balanced").tag(DuplicateScanViewModel.Strictness.balanced)
                Text("Loose").tag(DuplicateScanViewModel.Strictness.loose)
            }
            .pickerStyle(.segmented)

            Toggle("Also match approximate covers (recommended)", isOn: $appModel.duplicates.includeApproximate)
                .font(.callout)

            Toggle("Also match exact same cover image", isOn: $appModel.duplicates.includeExactChecksum)
                .font(.callout)

            Divider()

            Text("“Not a match” is saved locally and hides that pair in future scans.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Archives in the same Tankoubon are always ignored as duplicate candidates.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Show “Not a match” list") {
                showNotMatchesPanel = true
            }
            .font(.callout)

            Button("Clear “Not a match” decisions", role: .destructive) {
                showClearNotMatchesConfirmation = true
            }
            .font(.callout)

            Button("Show index database in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AppPaths.indexDBURL()])
            }
            .font(.callout)

            Divider()

            Text("Scans reuse the local cover index and only fetch new archives. Rebuild if covers changed on the server; it re-downloads every cover.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Rebuild index and scan") {
                section = .duplicates
                appModel.duplicates.start(profile: profile, rebuildIndex: true)
            }
            .font(.callout)
        }
        .confirmationDialog(
            "Clear all “Not a match” decisions?",
            isPresented: $showClearNotMatchesConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                appModel.duplicates.clearNotDuplicateDecisions(profile: profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all saved exclusions. Those pairs can appear in future duplicate scans again.")
        }
    }

    // Connection UI lives in Settings.
}

private struct SidebarVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .withinWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        // No-op; system handles reduced transparency automatically.
    }
}
