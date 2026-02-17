import AppKit
import SwiftUI

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

            content
                .padding(18)
                .background(
                    KeyDownCatcher { event in
                        handleKeyDown(event)
                    }
                    .frame(width: 0, height: 0)
                )
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                pageNavigationToolbarControl
            }

            ToolbarItemGroup(placement: .primaryAction) {
                autoAdvanceToolbarControl

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
                if readingDirection == .rtl {
                    goNext(userInitiated: true)
                } else {
                    goPrev(userInitiated: true)
                }
            case .right:
                if readingDirection == .rtl {
                    goPrev(userInitiated: true)
                } else {
                    goNext(userInitiated: true)
                }
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
            restartAutoAdvance(reason: .pageChanged)
        }
        .onChange(of: twoPageSpread) { _, _ in
            loadCurrentPage()
            restartAutoAdvance(reason: .settingsChanged)
        }
        .onChange(of: fitModeRaw) { _, _ in
            restartAutoAdvance(reason: .settingsChanged)
        }
        .onChange(of: zoomPercent) { _, _ in
            restartAutoAdvance(reason: .settingsChanged)
        }
        .onChange(of: autoAdvanceEnabled) { _, _ in
            restartAutoAdvance(reason: .settingsChanged)
        }
        .onChange(of: autoAdvanceSeconds) { _, newValue in
            let clamped = min(Self.autoAdvanceMaxSeconds, max(Self.autoAdvanceMinSeconds, newValue))
            if clamped != newValue {
                autoAdvanceSeconds = clamped
                return
            }
            restartAutoAdvance(reason: .settingsChanged)
        }
        .onChange(of: readingDirectionRaw) { _, _ in
            restartAutoAdvance(reason: .settingsChanged)
        }
        .onDisappear {
            timerTask?.cancel()
            loadTask?.cancel()
            prefetchTask?.cancel()
        }
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

    private var step: Int { twoPageSpread ? 2 : 1 }

    private var canGoNext: Bool {
        guard !pages.isEmpty else { return false }
        return (pageIndex + step) <= pages.count - 1
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
        return pageIndex > 0
    }

    private var canGoRightFromToolbar: Bool {
        if readingDirection == .rtl {
            return pageIndex > 0
        }
        return canGoNext
    }

    private var pageNavigationToolbarControl: some View {
        HStack(spacing: 10) {
            Button {
                if readingDirection == .rtl {
                    goNext(userInitiated: true)
                } else {
                    goPrev(userInitiated: true)
                }
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
                if readingDirection == .rtl {
                    goPrev(userInitiated: true)
                } else {
                    goNext(userInitiated: true)
                }
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
                    rtl: readingDirection == .rtl
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
                    // The side that advances depends on direction.
                    if readingDirection == .rtl {
                        goNext(userInitiated: true)
                    } else {
                        goPrev(userInitiated: true)
                    }
                }

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if readingDirection == .rtl {
                        goPrev(userInitiated: true)
                    } else {
                        goNext(userInitiated: true)
                    }
                }
        }
        .allowsHitTesting(!pages.isEmpty)
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

        guard let profile = currentProfile else {
            errorText = "Profile not found"
            return
        }

        do {
            let urls = try await appModel.archives.pageURLs(profile: profile, arcid: route.arcid)
            pages = urls
            pageIndex = 0
            loadCurrentPage()
            restartAutoAdvance(reason: .pageChanged)
        } catch {
            if Task.isCancelled { return }
            errorText = ErrorPresenter.short(error)
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
                let imgA = await MainActor.run { ImageDownsampler.thumbnail(from: bytesA, maxPixelSize: 2400) }
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
                    let imgB = await MainActor.run { ImageDownsampler.thumbnail(from: bytesB, maxPixelSize: 2400) }
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

    private enum AutoAdvanceRestartReason {
        case pageChanged
        case settingsChanged
        case userInteraction
    }

    private func restartAutoAdvance(reason: AutoAdvanceRestartReason) {
        // Manual navigation / interactions should reset the countdown.
        if reason == .userInteraction || reason == .pageChanged || reason == .settingsChanged {
            timerTask?.cancel()
            timerTask = nil
            countdownRemaining = nil
        }

        guard autoAdvanceEnabled else { return }
        guard pages.count > 1 else { return }

        // If we're already at the end, stop auto-advance.
        if pageIndex >= pages.count - 1 {
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

            // Finished countdown. If we're at the last page, stop; otherwise go next.
            if pageIndex >= pages.count - 1 {
                autoAdvanceEnabled = false
                countdownRemaining = nil
                return
            }

            goNext(userInitiated: false)
        }
    }

    private func goNext(userInitiated: Bool) {
        if userInitiated {
            restartAutoAdvance(reason: .userInteraction)
        }
        guard !pages.isEmpty else { return }

        let next = min(pages.count - 1, pageIndex + step)
        guard next != pageIndex else {
            if autoAdvanceEnabled {
                autoAdvanceEnabled = false
            }
            return
        }
        pageIndex = next
    }

    private func goPrev(userInitiated: Bool) {
        if userInitiated {
            restartAutoAdvance(reason: .userInteraction)
        }
        guard pageIndex > 0 else { return }
        pageIndex = max(0, pageIndex - step)
    }

    private func handleKeyDown(_ event: NSEvent) {
        // Space: next page. Shift-space: previous page.
        // Esc: close.
        switch event.keyCode {
        case 123: // left arrow
            if readingDirection == .rtl {
                goNext(userInitiated: true)
            } else {
                goPrev(userInitiated: true)
            }
        case 124: // right arrow
            if readingDirection == .rtl {
                goPrev(userInitiated: true)
            } else {
                goNext(userInitiated: true)
            }
        case 49: // space
            if event.modifierFlags.contains(.shift) {
                goPrev(userInitiated: true)
            } else {
                goNext(userInitiated: true)
            }
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

    var body: some View {
        GeometryReader { geo in
            let scale = scaleFor(container: geo.size)
            let z = max(0.5, min(2.0, zoomPercent / 100))
            let finalScale = scale * z

            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 16) {
                    if rtl, let b = imageB {
                        pageImage(b, px: pixelSizeB, scale: finalScale)
                        pageImage(image, px: pixelSize, scale: finalScale)
                    } else {
                        pageImage(image, px: pixelSize, scale: finalScale)
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
