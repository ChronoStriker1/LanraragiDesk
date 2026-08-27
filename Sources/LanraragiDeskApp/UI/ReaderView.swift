import AppKit
import SwiftUI
import LanraragiKit

struct ReaderView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let route: ReaderRoute

    @AppStorage("reader.autoAdvanceEnabled") private var autoAdvanceEnabled: Bool = false
    @AppStorage("reader.autoAdvanceSeconds") private var autoAdvanceSeconds: Double = 10
    @AppStorage("reader.readingDirection") private var readingDirectionRaw: String = ReaderDirection.ltr.rawValue
    @AppStorage("reader.twoPageSpread") private var twoPageSpread: Bool = false
    @AppStorage("reader.fitMode") private var fitModeRaw: String = ReaderFitMode.fit.rawValue
    @AppStorage("reader.zoomPercent") private var zoomPercent: Double = 100
    @AppStorage("reader.sidebarVisible") private var sidebarVisible: Bool = false

    @State private var pages: [URL] = []
    @State private var pageIndex: Int = 0

    @State private var image: NSImage?
    @State private var imageB: NSImage?
    @State private var imagePixelSize: CGSize?
    @State private var imageBPixelSize: CGSize?
    @State private var errorText: String?

    @State private var countdownRemaining: Int?
    @State private var timerTask: Task<Void, Never>?
    @State private var loadTask: Task<Void, Never>?
    @State private var prefetchTask: Task<Void, Never>?

    @AppStorage("reader.showStamps") private var showStamps: Bool = true
    @State private var currentStamps: [Stamp] = []
    @State private var stampedPages: Set<Int> = []
    @State private var stampsSupported: Bool = true
    @State private var addStampMode: Bool = false
    @State private var stampEditor: StampEditorRoute?
    @State private var stampsTask: Task<Void, Never>?

    enum StampEditorRoute: Identifiable {
        case new(x: Double, y: Double)
        case edit(Stamp)

        var id: String {
            switch self {
            case .new(let x, let y): return "new-\(x)-\(y)"
            case .edit(let stamp): return "edit-\(stamp.id)"
            }
        }
    }
    // Reserved for future in-reader UI toggles.
    // (Toolbar items should remain stable; avoid hiding controls unexpectedly.)

    private static let autoAdvanceMinSeconds: Double = 10
    private static let autoAdvanceMaxSeconds: Double = 60

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .controlBackgroundColor).opacity(0.85),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            HStack(spacing: 0) {
                if sidebarVisible && !pages.isEmpty, let profile = currentProfile {
                    ReaderPageSidebar(
                        profile: profile,
                        arcid: route.arcid,
                        pages: pages,
                        currentIndex: pageIndex,
                        stampedPages: showStamps ? stampedPages : [],
                        onJump: { idx in
                            pageIndex = ReaderNavigation.normalizedIndex(
                                idx,
                                pageCount: pages.count,
                                twoPageSpread: twoPageSpread
                            )
                            restartAutoAdvance()
                        },
                        onSetCover: { setPageAsCover(pageNumber: $0) }
                    )
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                content
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(KeyDownCatcher { handleKeyDown($0) }.frame(width: 0, height: 0))
            }
            .animation(.easeInOut(duration: 0.2), value: sidebarVisible)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                pageNavigationToolbarControl
            }

            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                        .imageScale(.medium)
                        .foregroundStyle(sidebarVisible ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .help(sidebarVisible ? "Hide page filmstrip" : "Show page filmstrip")
                .disabled(pages.isEmpty)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                autoAdvanceToolbarControl

                stampsToolbarMenu

                Menu {
                    Toggle("Two-page spread", isOn: $twoPageSpread)

                    Divider()

                    Picker("Fit", selection: $fitModeRaw) {
                        ForEach(ReaderFitMode.allCases) { m in
                            Text(m.title).tag(m.rawValue)
                        }
                    }

                    Menu("Zoom") {
                        Button("Increase") {
                            increaseZoom()
                        }
                        .keyboardShortcut("=", modifiers: [.command])

                        Button("Decrease") {
                            decreaseZoom()
                        }
                        .keyboardShortcut("-", modifiers: [.command])

                        Divider()

                        Button("Reset") {
                            resetZoom()
                        }
                        .keyboardShortcut("0", modifiers: [.command])
                    }

                    Text("Current zoom: \(Int(zoomPercent.rounded()))%")

                    Divider()

                    Button("Open in LANraragi") {
                        openInLANraragi()
                    }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                } label: {
                    Image(systemName: "rectangle.3.group")
                        .imageScale(.medium)
                }
                .help("Reader view options")
            }
        }
        .onMoveCommand { dir in
            switch dir {
            case .left:
                performNavigation(.moveLeft, userInitiated: true)
            case .right:
                performNavigation(.moveRight, userInitiated: true)
            default:
                break
            }
        }
        .task(id: route) {
            await loadArchive()
        }
        .onAppear {
            clampAutoAdvanceSecondsIfNeeded()
        }
        .onChange(of: pageIndex) { _, _ in
            loadCurrentPage()
            reloadStamps()
            restartAutoAdvance()
        }
        .sheet(item: $stampEditor) { route in
            StampEditorSheet(
                route: route,
                onSave: { text in commitStampEdit(route: route, content: text) },
                onDelete: {
                    if case .edit(let stamp) = route {
                        removeStamp(stamp)
                    }
                }
            )
        }
        .onChange(of: twoPageSpread) { _, enabled in
            let normalized = ReaderNavigation.normalizedIndex(
                pageIndex,
                pageCount: pages.count,
                twoPageSpread: enabled
            )
            if normalized != pageIndex {
                // The pageIndex observer owns the reload and timer restart when
                // normalization changes the selection.
                pageIndex = normalized
            } else {
                // No pageIndex notification will fire, so update in place.
                loadCurrentPage()
                restartAutoAdvance()
            }
        }
        .onChange(of: fitModeRaw) { _, _ in
            restartAutoAdvance()
        }
        .onChange(of: zoomPercent) { _, _ in
            restartAutoAdvance()
        }
        .onChange(of: autoAdvanceEnabled) { _, _ in
            restartAutoAdvance()
        }
        .onChange(of: autoAdvanceSeconds) { _, newValue in
            let clamped = min(Self.autoAdvanceMaxSeconds, max(Self.autoAdvanceMinSeconds, newValue))
            if clamped != newValue {
                autoAdvanceSeconds = clamped
                return
            }
            restartAutoAdvance()
        }
        .onChange(of: readingDirectionRaw) { _, _ in
            restartAutoAdvance()
        }
        .onDisappear {
            timerTask?.cancel()
            loadTask?.cancel()
            prefetchTask?.cancel()
            stampsTask?.cancel()
        }
    }

    private var stampsToolbarMenu: some View {
        Menu {
            Toggle("Show stamps", isOn: $showStamps)

            Toggle("Add stamp on click", isOn: $addStampMode)
                .disabled(twoPageSpread || !stampsSupported)

            if twoPageSpread {
                Text("Stamps are hidden in two-page spread")
            }

            if !currentStamps.isEmpty {
                Divider()
                ForEach(currentStamps) { stamp in
                    Menu(stamp.content.isEmpty ? "(no text)" : stamp.content) {
                        Button("Edit…") { stampEditor = .edit(stamp) }
                        Button("Delete", role: .destructive) { removeStamp(stamp) }
                    }
                }
            }
        } label: {
            Image(systemName: currentStamps.isEmpty ? "seal" : "seal.fill")
                .imageScale(.medium)
                .foregroundStyle(addStampMode ? Color.accentColor : Color.primary)
        }
        .help(stampsSupported ? "Stamps on this page (\(currentStamps.count))" : "Stamps require a newer LANraragi server")
        .disabled(pages.isEmpty || !stampsSupported)
    }

    private var readingDirection: ReaderDirection {
        ReaderDirection(rawValue: readingDirectionRaw) ?? .ltr
    }

    private var currentProfile: Profile? {
        appModel.profileStore.profiles.first(where: { $0.id == route.profileID })
    }

    private var fitMode: ReaderFitMode {
        ReaderFitMode(rawValue: fitModeRaw) ?? .fit
    }

    private var canGoNext: Bool {
        if case .page = ReaderNavigation.advance(
            from: pageIndex,
            pageCount: pages.count,
            twoPageSpread: twoPageSpread
        ) {
            return true
        }
        return false
    }

    private var canGoPrevious: Bool {
        if case .page = ReaderNavigation.retreat(
            from: pageIndex,
            pageCount: pages.count,
            twoPageSpread: twoPageSpread
        ) {
            return true
        }
        return false
    }

    private var clampedAutoAdvanceSeconds: Double {
        min(Self.autoAdvanceMaxSeconds, max(Self.autoAdvanceMinSeconds, autoAdvanceSeconds))
    }

    private var activeCountdownSeconds: Int {
        countdownRemaining ?? Int(clampedAutoAdvanceSeconds.rounded())
    }

    private var autoAdvanceDisplayedSeconds: Int {
        autoAdvanceEnabled ? activeCountdownSeconds : Int(clampedAutoAdvanceSeconds.rounded())
    }

    private var leftToolbarHelp: String {
        readingDirection == .rtl ? "Next page" : "Previous page"
    }

    private var rightToolbarHelp: String {
        readingDirection == .rtl ? "Previous page" : "Next page"
    }

    private var canGoLeftFromToolbar: Bool {
        if readingDirection == .rtl {
            return canGoNext
        }
        return canGoPrevious
    }

    private var canGoRightFromToolbar: Bool {
        if readingDirection == .rtl {
            return canGoPrevious
        }
        return canGoNext
    }

    private var pageNavigationToolbarControl: some View {
        HStack(spacing: 10) {
            Button {
                performNavigation(.toolbarLeft, userInitiated: true)
            } label: {
                Image(systemName: "chevron.left")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .disabled(!canGoLeftFromToolbar)
            .help(leftToolbarHelp)

            Text(pageCountText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .center)

            Button {
                performNavigation(.toolbarRight, userInitiated: true)
            } label: {
                Image(systemName: "chevron.right")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .disabled(!canGoRightFromToolbar)
            .help(rightToolbarHelp)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.3))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.thinMaterial)

            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .padding(16)
            } else if image != nil {
                ReaderCanvas(
                    image: image,
                    imageB: twoPageSpread ? imageB : nil,
                    pixelSize: imagePixelSize,
                    pixelSizeB: twoPageSpread ? imageBPixelSize : nil,
                    fitMode: fitMode,
                    zoomPercent: zoomPercent,
                    rtl: readingDirection == .rtl,
                    stamps: (showStamps && !twoPageSpread) ? currentStamps : [],
                    addStampMode: addStampMode && !twoPageSpread,
                    onAddStamp: { x, y in
                        stampEditor = .new(x: x, y: y)
                    },
                    onSelectStamp: { stamp in
                        stampEditor = .edit(stamp)
                    }
                )
                .padding(10)
            } else {
                ProgressView()
                    .padding(20)
            }

            clickZones
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clickZones: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    performNavigation(.clickLeft, userInitiated: true)
                }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    performNavigation(.clickRight, userInitiated: true)
                }
        }
        // In add-stamp mode clicks must reach the page image, not turn pages.
        .allowsHitTesting(!pages.isEmpty && !addStampMode)
        .help("Click to change pages")
    }

    private var pageCountText: String {
        guard !pages.isEmpty else { return "—/—" }
        return "\(pageIndex + 1)/\(pages.count)"
    }

    private var autoAdvanceToolbarControl: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Button {
                    autoAdvanceEnabled.toggle()
                } label: {
                    Image(systemName: autoAdvanceEnabled ? "clock.badge.checkmark" : "clock")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help("Toggle auto page turn")

                Slider(
                    value: $autoAdvanceSeconds,
                    in: Self.autoAdvanceMinSeconds...Self.autoAdvanceMaxSeconds,
                    step: 1
                )
                .frame(width: 84)
                .controlSize(.small)

                Text("\(autoAdvanceDisplayedSeconds)s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.3))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }
            .frame(width: 164, alignment: .leading)
            .help("Auto page turn")

            HStack(spacing: 6) {
                Button {
                    autoAdvanceEnabled.toggle()
                } label: {
                    Image(systemName: autoAdvanceEnabled ? "clock.badge.checkmark" : "clock")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .help("Toggle auto page turn")

                Menu("\(autoAdvanceDisplayedSeconds)s") {
                    Button("Slower ( +5s )") {
                        autoAdvanceSeconds = min(Self.autoAdvanceMaxSeconds, autoAdvanceSeconds + 5)
                    }
                    Button("Faster ( -5s )") {
                        autoAdvanceSeconds = max(Self.autoAdvanceMinSeconds, autoAdvanceSeconds - 5)
                    }
                }
                .font(.caption.monospacedDigit())
                .menuStyle(.borderlessButton)
                .help("Adjust auto page turn delay")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.3))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }
            .help("Auto page turn")
        }
    }

    private func loadArchive() async {
        // Auto page turn should always start disabled when opening a new archive.
        autoAdvanceEnabled = false
        pages = []
        image = nil
        imageB = nil
        imagePixelSize = nil
        imageBPixelSize = nil
        errorText = nil
        countdownRemaining = nil
        timerTask?.cancel()
        loadTask?.cancel()
        prefetchTask?.cancel()
        stampsTask?.cancel()
        currentStamps = []
        stampedPages = []
        stampsSupported = true
        addStampMode = false

        guard let profile = currentProfile else {
            errorText = "Profile not found"
            return
        }

        do {
            let urls = try await appModel.archives.pageURLs(profile: profile, arcid: route.arcid)
            pages = urls
            pageIndex = 0
            loadCurrentPage()
            reloadStamps()
            restartAutoAdvance()
        } catch {
            if Task.isCancelled { return }
            errorText = ErrorPresenter.short(error)
        }
    }

    /// Fetches the stamped-pages summary and the stamps for the current page.
    private func reloadStamps() {
        stampsTask?.cancel()
        currentStamps = []

        guard stampsSupported, let profile = currentProfile, !pages.isEmpty else { return }
        let page = pageIndex + 1

        stampsTask = Task {
            do {
                let stamps = try await appModel.archives.stamps(profile: profile, arcid: route.arcid, page: page)
                if Task.isCancelled { return }
                currentStamps = stamps

                let stamped = try await appModel.archives.stampedPages(profile: profile, arcid: route.arcid)
                if Task.isCancelled { return }
                stampedPages = Set(stamped)
            } catch let LANraragiError.httpStatus(code, _) where code == 404 {
                // Older server without the Stamp API; stop asking.
                stampsSupported = false
            } catch {
                // Stamps are non-critical; don't surface transient failures over the page.
            }
        }
    }

    private func commitStampEdit(route editorRoute: StampEditorRoute, content: String) {
        guard let profile = currentProfile else { return }
        let page = pageIndex + 1

        Task {
            do {
                switch editorRoute {
                case .new(let x, let y):
                    let position = Stamp.positionString(x: x, y: y)
                    try await appModel.archives.addStamp(
                        profile: profile,
                        arcid: route.arcid,
                        page: page,
                        content: content,
                        position: position
                    )
                    appModel.activity.add(.init(kind: .action, title: "Added stamp", detail: "Page \(page)", component: "Reader"))
                case .edit(let stamp):
                    try await appModel.archives.updateStamp(profile: profile, stampID: stamp.id, content: content)
                    appModel.activity.add(.init(kind: .action, title: "Updated stamp", detail: stamp.id, component: "Reader"))
                }
                reloadStamps()
            } catch {
                appModel.activity.add(.init(kind: .error, title: "Stamp save failed", detail: String(describing: error), component: "Reader"))
            }
        }
    }

    private func removeStamp(_ stamp: Stamp) {
        guard let profile = currentProfile else { return }
        Task {
            do {
                try await appModel.archives.deleteStamp(profile: profile, stampID: stamp.id)
                appModel.activity.add(.init(kind: .action, title: "Deleted stamp", detail: stamp.id, component: "Reader"))
                reloadStamps()
            } catch {
                appModel.activity.add(.init(kind: .error, title: "Stamp delete failed", detail: String(describing: error), component: "Reader"))
            }
        }
    }

    private func loadCurrentPage() {
        loadTask?.cancel()
        image = nil
        imageB = nil
        imagePixelSize = nil
        imageBPixelSize = nil
        errorText = nil

        guard let profile = currentProfile else {
            errorText = "Profile not found"
            return
        }
        guard pageIndex >= 0, pageIndex < pages.count else {
            errorText = "Missing page"
            return
        }
        let urlA = pages[pageIndex]
        let idxB = pageIndex + 1
        let urlB = (twoPageSpread && idxB < pages.count) ? pages[idxB] : nil

        loadTask = Task {
            do {
                let bytesA = try await appModel.archives.bytes(profile: profile, url: urlA)
                let pxA = ImageDownsampler.pixelSize(from: bytesA)
                let imgA = ImageDownsampler.thumbnail(from: bytesA, maxPixelSize: 2400)
                if Task.isCancelled { return }
                if let imgA {
                    self.image = imgA
                    self.imagePixelSize = pxA
                } else {
                    self.errorText = "Decode failed"
                }

                if let urlB {
                    let bytesB = try await appModel.archives.bytes(profile: profile, url: urlB)
                    let pxB = ImageDownsampler.pixelSize(from: bytesB)
                    let imgB = ImageDownsampler.thumbnail(from: bytesB, maxPixelSize: 2400)
                    if Task.isCancelled { return }
                    self.imageB = imgB
                    self.imageBPixelSize = pxB
                }

                startPrefetch(profile: profile)
            } catch {
                if Task.isCancelled { return }
                self.errorText = ErrorPresenter.short(error)
            }
        }
    }

    private func startPrefetch(profile: Profile) {
        prefetchTask?.cancel()

        guard !pages.isEmpty else { return }
        let candidates: [Int] = {
            if twoPageSpread {
                return [pageIndex + 2, pageIndex + 3, pageIndex - 1]
            } else {
                return [pageIndex + 1, pageIndex + 2, pageIndex - 1]
            }
        }()
        let indices = candidates.filter { $0 >= 0 && $0 < pages.count }
        if indices.isEmpty { return }

        prefetchTask = Task.detached(priority: .utility) { [pages] in
            await withTaskGroup(of: Void.self) { group in
                // Prefetch is intentionally light: decode a downsampled image and let ArchiveLoader manage bytes.
                for idx in indices.prefix(3) {
                    group.addTask {
                        do {
                            let url = pages[idx]
                            let bytes = try await self.appModel.archives.bytes(profile: profile, url: url)
                            _ = ImageDownsampler.thumbnail(from: bytes, maxPixelSize: 1800)
                        } catch {
                            // Best-effort prefetch; ignore errors.
                        }
                    }
                }
            }
        }
    }

    private func restartAutoAdvance() {
        // Any restart resets the current countdown before scheduling a new one.
        timerTask?.cancel()
        timerTask = nil
        countdownRemaining = nil

        guard autoAdvanceEnabled else { return }
        guard pages.count > 1 else { return }

        // If we're already at the final page or spread, stop auto-advance.
        guard canGoNext else {
            autoAdvanceEnabled = false
            return
        }

        let seconds = Int(clampedAutoAdvanceSeconds.rounded())
        countdownRemaining = seconds

        timerTask = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
                countdownRemaining = remaining
            }

            // The page may have changed during the countdown. Recheck the same
            // navigation decision used by every other page-turn input.
            guard canGoNext else {
                autoAdvanceEnabled = false
                countdownRemaining = nil
                return
            }

            performNavigation(.autoAdvance, userInitiated: false)
        }
    }

    private func performNavigation(
        _ input: ReaderNavigationInput,
        userInitiated: Bool
    ) {
        if userInitiated {
            restartAutoAdvance()
        }
        switch ReaderNavigation.decision(
            for: input,
            from: pageIndex,
            pageCount: pages.count,
            twoPageSpread: twoPageSpread,
            rightToLeft: readingDirection == .rtl
        ) {
        case .page(let destination):
            pageIndex = destination
        case .endOfArchive:
            if autoAdvanceEnabled {
                autoAdvanceEnabled = false
            }
        case .startOfArchive:
            break
        }
        case .startOfArchive:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Space: next page. Shift-space: previous page.
        // Esc: close.
        switch event.keyCode {
        case 123: // left arrow
            performNavigation(.keyboardLeft, userInitiated: true)
        case 124: // right arrow
            performNavigation(.keyboardRight, userInitiated: true)
        case 49: // space
            performNavigation(
                .space(shifted: event.modifierFlags.contains(.shift)),
                userInitiated: true
            )
        case 53: // escape
            dismiss()
        case 24, 69: // + on some keyboards, numpad +
            increaseZoom()
        case 27, 78: // - on some keyboards, numpad -
            decreaseZoom()
        case 29: // 0
            resetZoom()
        default:
            break
        }
    }

    private func increaseZoom() {
        zoomPercent = min(200, zoomPercent + 10)
    }

    private func decreaseZoom() {
        zoomPercent = max(50, zoomPercent - 10)
    }

    private func resetZoom() {
        zoomPercent = 100
    }

    private func clampAutoAdvanceSecondsIfNeeded() {
        let clamped = clampedAutoAdvanceSeconds
        if clamped != autoAdvanceSeconds {
            autoAdvanceSeconds = clamped
        }
    }

    private func setPageAsCover(pageNumber: Int) {
        guard let profile = currentProfile else { return }
        Task {
            do {
                try await appModel.archives.updateThumbnail(
                    profile: profile, arcid: route.arcid, page: pageNumber)
                await appModel.thumbnails.invalidate(profile: profile, arcid: route.arcid)
                CoverThumbInvalidationStore.shared.invalidate(
                    profileID: profile.id, arcid: route.arcid)
                appModel.activity.add(.init(
                    kind: .action, title: "Cover updated",
                    detail: "Page \(pageNumber)", component: "Reader"))
            } catch {
                appModel.activity.add(.init(
                    kind: .error, title: "Cover update failed",
                    detail: String(describing: error), component: "Reader"))
            }
        }
    }

    private func openInLANraragi() {
        guard
            let profile = currentProfile,
            var comps = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false)
        else { return }
        comps.path = "/reader"
        comps.queryItems = [URLQueryItem(name: "id", value: route.arcid)]
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
        appModel.activity.add(.init(kind: .action, title: "Opened in LANraragi", detail: route.arcid, component: "Reader"))
    }
}

private struct ReaderCanvas: View {
    let image: NSImage?
    let imageB: NSImage?
    let pixelSize: CGSize?
    let pixelSizeB: CGSize?
    let fitMode: ReaderFitMode
    let zoomPercent: Double
    let rtl: Bool
    var stamps: [Stamp] = []
    var addStampMode: Bool = false
    var onAddStamp: ((Double, Double) -> Void)? = nil
    var onSelectStamp: ((Stamp) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let scale = scaleFor(container: geo.size)
            let z = max(0.5, min(2.0, zoomPercent / 100))
            let finalScale = scale * z

            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 16) {
                    if rtl, let b = imageB {
                        pageImage(b, px: pixelSizeB, scale: finalScale)
                        primaryPageImage(scale: finalScale)
                    } else {
                        primaryPageImage(scale: finalScale)
                        if let b = imageB {
                            pageImage(b, px: pixelSizeB, scale: finalScale)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The current page, with the stamp overlay attached.
    @ViewBuilder
    private func primaryPageImage(scale: CGFloat) -> some View {
        pageImage(image, px: pixelSize, scale: scale)
            .overlay {
                if !stamps.isEmpty || addStampMode {
                    StampOverlay(
                        stamps: stamps,
                        interactive: addStampMode,
                        onTapEmpty: { nx, ny in onAddStamp?(nx, ny) },
                        onTapStamp: { stamp in onSelectStamp?(stamp) }
                    )
                }
            }
    }

    @ViewBuilder
    private func pageImage(_ img: NSImage?, px: CGSize?, scale: CGFloat) -> some View {
        if let img, let px {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: px.width * scale, height: px.height * scale)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if let img {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    private func scaleFor(container: CGSize) -> CGFloat {
        guard let px = pixelSize, px.width > 0, px.height > 0 else { return 1 }
        let availableW = max(1, container.width - 20)
        let availableH = max(1, container.height - 20)

        switch fitMode {
        case .actualSize:
            return 1
        case .fitWidth:
            let spreadCount: CGFloat = imageB == nil ? 1 : 2
            let totalW = px.width * spreadCount + (imageB == nil ? 0 : 16)
            return min(10, availableW / max(1, totalW))
        case .fit:
            let spreadCount: CGFloat = imageB == nil ? 1 : 2
            let totalW = px.width * spreadCount + (imageB == nil ? 0 : 16)
            let wScale = availableW / max(1, totalW)
            let hScale = availableH / max(1, px.height)
            return min(10, min(wScale, hScale))
        }
    }
}

/// Positions stamp markers over the page in normalized (0–100) coordinates.
/// When `interactive`, taps on empty space report a new stamp position and
/// markers become clickable for editing.
private struct StampOverlay: View {
    let stamps: [Stamp]
    let interactive: Bool
    let onTapEmpty: (Double, Double) -> Void
    let onTapStamp: (Stamp) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if interactive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { point in
                            guard geo.size.width > 0, geo.size.height > 0 else { return }
                            let nx = Double(point.x / geo.size.width) * 100
                            let ny = Double(point.y / geo.size.height) * 100
                            onTapEmpty(nx, ny)
                        }
                }

                ForEach(stamps) { stamp in
                    if let pos = stamp.normalizedPoint {
                        marker(for: stamp)
                            .position(
                                x: geo.size.width * CGFloat(pos.x) / 100,
                                y: geo.size.height * CGFloat(pos.y) / 100
                            )
                    }
                }
            }
        }
        .allowsHitTesting(interactive)
    }

    private func marker(for stamp: Stamp) -> some View {
        Button {
            onTapStamp(stamp)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "seal.fill")
                    .imageScale(.small)
                    .foregroundStyle(.yellow)
                if !stamp.content.isEmpty {
                    Text(stamp.content)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: 160)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.black.opacity(0.65))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .help(stamp.content.isEmpty ? "Stamp" : stamp.content)
    }
}

/// Sheet for entering/editing stamp text.
private struct StampEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let route: ReaderView.StampEditorRoute
    let onSave: (String) -> Void
    let onDelete: () -> Void

    @State private var text: String = ""

    private var isEditing: Bool {
        if case .edit = route { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEditing ? "Edit Stamp" : "New Stamp")
                .font(.title3.weight(.semibold))

            TextField("Stamp text…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .frame(minWidth: 320)
                .onSubmit { save() }

            HStack {
                if isEditing {
                    Button("Delete", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .onAppear {
            if case .edit(let stamp) = route {
                text = stamp.content
            }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

private struct ReaderPageSidebar: View {
    @EnvironmentObject private var appModel: AppModel

    let profile: Profile
    let arcid: String
    let pages: [URL]
    let currentIndex: Int
    let stampedPages: Set<Int>  // 1-indexed page numbers
    let onJump: (Int) -> Void
    let onSetCover: (Int) -> Void  // 1-indexed page number

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pages")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(pages.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { idx, url in
                            PageThumbnailCell(
                                profile: profile,
                                url: url,
                                pageNumber: idx + 1,
                                isCurrent: idx == currentIndex,
                                hasStamp: stampedPages.contains(idx + 1),
                                onTap: { onJump(idx) },
                                onSetCover: { onSetCover(idx + 1) }
                            )
                            .id(idx)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.visible)
                .onChange(of: currentIndex) { _, newIdx in
                    withAnimation { proxy.scrollTo(newIdx, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
            }
        }
        .frame(width: 130)
        .background(.thinMaterial)
    }
}

private struct PageThumbnailCell: View {
    @EnvironmentObject private var appModel: AppModel

    let profile: Profile
    let url: URL
    let pageNumber: Int
    let isCurrent: Bool
    let hasStamp: Bool
    let onTap: () -> Void
    let onSetCover: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isLoading = true

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else if isLoading {
                    Rectangle()
                        .fill(.quaternary.opacity(0.35))
                        .frame(height: 150)
                        .overlay { ProgressView().controlSize(.mini) }
                } else {
                    Rectangle()
                        .fill(.quaternary.opacity(0.35))
                        .frame(height: 150)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 110)

            Text("\(pageNumber)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55))
                .clipShape(Capsule())
                .padding(.bottom, 5)
        }
        .frame(width: 110)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hasStamp {
                Image(systemName: "seal.fill")
                    .imageScale(.small)
                    .foregroundStyle(.yellow)
                    .padding(3)
                    .background(.black.opacity(0.55))
                    .clipShape(Circle())
                    .padding(4)
                    .help("This page has stamps")
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .shadow(color: isCurrent ? Color.accentColor.opacity(0.4) : .clear, radius: 5)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button("Set as Cover") { onSetCover() }
        }
        .task(id: url) {
            isLoading = true
            thumbnail = nil
            do {
                let bytes = try await appModel.archives.bytes(profile: profile, url: url)
                thumbnail = ImageDownsampler.thumbnail(from: bytes, maxPixelSize: 240)
            } catch {
                // placeholder shown on failure
            }
            isLoading = false
        }
    }
}

private struct KeyDownCatcher: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.onKeyDown = onKeyDown
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? CatcherView else { return }
        v.onKeyDown = onKeyDown
    }

    private final class CatcherView: NSView {
        var onKeyDown: ((NSEvent) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                if window.firstResponder !== self {
                    window.makeFirstResponder(self)
                }
            }
        }

        override func keyDown(with event: NSEvent) {
            onKeyDown?(event)
        }
    }
}
