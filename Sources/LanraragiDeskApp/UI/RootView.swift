import AppKit
import SwiftUI
import LanraragiKit

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var showNotMatchesPanel: Bool = false
    @State private var collapseRunCard: Bool = false
    @State private var section: Section = .library
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
        .onReceive(appModel.$librarySearchRequest) { request in
            guard let request else { return }
            guard request.profileID == appModel.selectedProfileID else { return }
            section = .library
        }
        .sheet(item: $appModel.profileEditorMode) { mode in
            ProfileEditorView(mode: mode)
        }
        .onChange(of: appModel.duplicates.resultRevision) { _, _ in
            // Keep users on the Duplicates workspace and collapse controls when results are ready.
            if case .completed = appModel.duplicates.status, appModel.duplicates.result != nil {
                section = .duplicates
                collapseRunCard = true
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
                .help(sidebarVisible ? "Hide Sidebar" : "Show Sidebar")
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
            .background(TitlebarSidebarToggleHost(isSidebarVisible: $sidebarVisible))
        } else {
            ContentUnavailableView(
                "Connect To LANraragi",
                systemImage: "server.rack",
                description: Text("Set your server address and API key to start finding duplicates.")
            )
            .frame(minWidth: 700, minHeight: 520)
        }
    }

    private var sidebar: some View {
        ZStack {
            // Finder-like frosted background that respects system reduced-transparency settings.
            SidebarVibrancy()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    sidebarButton(title: "Library", systemImage: "books.vertical", section: .library)
                    if showStatisticsPage {
                        sidebarButton(title: "Statistics", systemImage: "chart.bar.xaxis", section: .statistics)
                    }

                    Divider().padding(.vertical, 8)

                    sidebarButton(title: "Duplicates", systemImage: "doc.on.doc", section: .duplicates)
                    sidebarButton(title: "Activity", systemImage: "list.bullet.rectangle", section: .activity)
                    sidebarButton(title: "Batch", systemImage: "square.stack.3d.forward.dottedline", section: .batch)

                    Divider().padding(.vertical, 8)
                    sidebarButton(title: "Settings", systemImage: "gearshape", section: .settings)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
    }

    private func sidebarButton(title: String, systemImage: String, section target: Section) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 18)
            Text(title)
                .font(.body.weight(.medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(section == target ? Color.primary : Color.primary.opacity(0.88))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(section == target ? Color.primary.opacity(0.12) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            section = target
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(section == target ? .isSelected : [])
    }

    private func detail(profile: Profile) -> some View {
        ZStack {
            LibraryView(profile: profile)
                .environmentObject(appModel)
                .opacity(section == .library ? 1 : 0)
                .allowsHitTesting(section == .library)
                .accessibilityHidden(section != .library)

            if showStatisticsPage {
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

            BatchView()
                .environmentObject(appModel)
                .opacity(section == .batch ? 1 : 0)
                .allowsHitTesting(section == .batch)
                .accessibilityHidden(section != .batch)

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

    @ViewBuilder
    private func duplicatesWorkspace(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            runCard(profile: profile)

            if appModel.duplicates.result != nil {
                reviewTab(profile: profile)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Results Yet",
                    systemImage: "square.stack.3d.up.slash",
                    description: Text("Run a scan to see duplicate groups here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            ContentUnavailableView(
                "No Results Yet",
                systemImage: "square.stack.3d.up.slash",
                description: Text("Run a scan to see duplicate groups here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func runCard(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Find Duplicate Archives")
                        .font(.title2)
                        .bold()

                    if !collapseRunCard {
                        Text("Click Find Duplicates. The app will update its local index if needed, then show you likely duplicates to review and delete manually.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if appModel.duplicates.result != nil {
                    Button(collapseRunCard ? "Expand" : "Collapse") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            collapseRunCard.toggle()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !collapseRunCard {
                Divider()

                HStack(spacing: 12) {
                    Button {
                        section = .duplicates
                        collapseRunCard = false
                        appModel.duplicates.start(profile: profile)
                    } label: {
                        Text("Find Duplicates")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Cancel", role: .destructive) { appModel.duplicates.cancel() }

                    Spacer()
                }

                statusBlock(profile: profile)

                DisclosureGroup("Advanced") {
                    advancedOptions(profile: profile)
                        .padding(.top, 8)
                }
                .font(.callout)
            }
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .debugFrameNumber(1)
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
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            case .completed(let stats):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Found \(appModel.duplicates.result?.groups.count ?? 0) duplicate groups.")
                        .font(.callout)
                    Text("Scanned \(stats.archives) archives in \(String(format: "%.1fs", stats.durationSeconds)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Duplicate scan failed.")
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

            Button(showNotMatchesPanel ? "Hide “Not a match” list" : "Show “Not a match” list") {
                showNotMatchesPanel.toggle()
                if showNotMatchesPanel {
                    Task { await appModel.duplicates.loadNotDuplicatePairs(profile: profile) }
                }
            }
            .font(.callout)

            if showNotMatchesPanel {
                NotMatchesView(profile: profile, embedded: true)
                    .environmentObject(appModel)
                    .frame(maxWidth: .infinity)
            }

            Button("Clear “Not a match” decisions", role: .destructive) {
                appModel.duplicates.clearNotDuplicateDecisions(profile: profile)
            }
            .font(.callout)

            Button("Show index database in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AppPaths.indexDBURL()])
            }
            .font(.callout)
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

private struct TitlebarSidebarToggleHost: NSViewRepresentable {
    @Binding var isSidebarVisible: Bool

    func makeNSView(context: Context) -> TitlebarSidebarToggleNSView {
        let view = TitlebarSidebarToggleNSView()
        view.onToggle = {
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isSidebarVisible.toggle()
                }
            }
        }
        view.isSidebarVisible = isSidebarVisible
        return view
    }

    func updateNSView(_ nsView: TitlebarSidebarToggleNSView, context: Context) {
        nsView.onToggle = {
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isSidebarVisible.toggle()
                }
            }
        }
        nsView.isSidebarVisible = isSidebarVisible
        nsView.installIfNeeded()
    }
}

private final class TitlebarSidebarToggleNSView: NSView {
    private static let toggleIdentifier = NSUserInterfaceItemIdentifier("LanraragiDesk.TitlebarSidebarToggle")

    var onToggle: (() -> Void)?
    var isSidebarVisible: Bool = true {
        didSet { updateButtonImage() }
    }

    private weak var toggleButton: NSButton?
    private weak var fallbackAccessoryButton: NSButton?
    private weak var fallbackAccessoryController: NSTitlebarAccessoryViewController?
    private weak var observedWindow: NSWindow?
    private var hasScheduledRetry: Bool = false

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installIfNeeded()
        registerWindowObservers()
    }

    func installIfNeeded() {
        guard let window else { return }
        if installNearTrafficLights(window: window) {
            hasScheduledRetry = false
            removeFallbackAccessoryIfNeeded(window: window)
            return
        }

        if installAccessoryFallback(window: window) {
            hasScheduledRetry = false
            return
        }

        scheduleInstallRetry()
    }

    @objc private func didPressToggleButton() {
        onToggle?()
    }

    private func installNearTrafficLights(window: NSWindow) -> Bool {
        guard let mini = window.standardWindowButton(.miniaturizeButton),
              let miniSuperview = mini.superview else { return false }

        removeStaleToggleButtons(window: window, keepSuperview: miniSuperview)

        if let existing = miniSuperview.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.identifier == Self.toggleIdentifier }) {
            toggleButton = existing
            fallbackAccessoryButton = nil
            fallbackAccessoryController = nil
            updateButtonImage()
            return true
        }

        let button = NSButton(frame: .zero)
        button.identifier = Self.toggleIdentifier
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.bezelStyle = .texturedRounded
        button.controlSize = mini.controlSize
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Toggle Sidebar"
        button.target = self
        button.action = #selector(didPressToggleButton)

        miniSuperview.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: mini.trailingAnchor, constant: 6),
            button.centerYAnchor.constraint(equalTo: mini.centerYAnchor),
            button.widthAnchor.constraint(equalTo: mini.widthAnchor),
            button.heightAnchor.constraint(equalTo: mini.heightAnchor)
        ])

        toggleButton = button
        fallbackAccessoryButton = nil
        fallbackAccessoryController = nil
        updateButtonImage()
        return true
    }

    private func installAccessoryFallback(window: NSWindow) -> Bool {
        if let existing = fallbackAccessoryController,
           window.titlebarAccessoryViewControllers.contains(existing) {
            updateButtonImage()
            return true
        }

        let button = NSButton(frame: .zero)
        button.identifier = Self.toggleIdentifier
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Toggle Sidebar"
        button.target = self
        button.action = #selector(didPressToggleButton)

        let host = NSView(frame: .init(x: 0, y: 0, width: 20, height: 20))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            button.topAnchor.constraint(equalTo: host.topAnchor),
            button.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.widthAnchor.constraint(equalToConstant: 20),
            host.heightAnchor.constraint(equalToConstant: 20),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .left
        accessory.view = host
        window.addTitlebarAccessoryViewController(accessory)

        fallbackAccessoryController = accessory
        fallbackAccessoryButton = button
        toggleButton = nil
        updateButtonImage()
        return true
    }

    private func removeFallbackAccessoryIfNeeded(window: NSWindow) {
        guard let accessory = fallbackAccessoryController else { return }
        if let idx = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
            window.titlebarAccessoryViewControllers.remove(at: idx)
        }
        fallbackAccessoryController = nil
        fallbackAccessoryButton = nil
    }

    private func scheduleInstallRetry() {
        guard !hasScheduledRetry else { return }
        hasScheduledRetry = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.hasScheduledRetry = false
            self.installIfNeeded()
        }
    }

    private func updateButtonImage() {
        let symbol = isSidebarVisible ? "sidebar.left" : "sidebar.right"
        toggleButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle Sidebar")
        fallbackAccessoryButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle Sidebar")
    }

    private func removeStaleToggleButtons(window: NSWindow, keepSuperview: NSView) {
        guard let frameView = window.contentView?.superview else { return }
        for button in findToggleButtons(in: frameView) where button.superview !== keepSuperview {
            button.removeFromSuperview()
        }
    }

    private func findToggleButtons(in root: NSView) -> [NSButton] {
        var result: [NSButton] = []
        if let button = root as? NSButton, button.identifier == Self.toggleIdentifier {
            result.append(button)
        }
        for child in root.subviews {
            result.append(contentsOf: findToggleButtons(in: child))
        }
        return result
    }

    private func registerWindowObservers() {
        guard window !== observedWindow else { return }
        NotificationCenter.default.removeObserver(self)
        observedWindow = window

        guard let window else { return }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowGeometryDidChange), name: NSWindow.didResizeNotification, object: window)
        center.addObserver(self, selector: #selector(windowGeometryDidChange), name: NSWindow.didMoveNotification, object: window)
        center.addObserver(self, selector: #selector(windowGeometryDidChange), name: NSWindow.didEndLiveResizeNotification, object: window)
        center.addObserver(self, selector: #selector(windowGeometryDidChange), name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @objc private func windowGeometryDidChange(_ notification: Notification) {
        installIfNeeded()
    }
}
