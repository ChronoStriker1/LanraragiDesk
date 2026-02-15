import AppKit
import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let route: ReaderRoute

    @AppStorage("reader.autoAdvanceEnabled") private var autoAdvanceEnabled: Bool = false
    @AppStorage("reader.autoAdvanceSeconds") private var autoAdvanceSeconds: Double = 8
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
    @State private var isViewingControls: Bool = false

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
        .navigationTitle(titleText)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if readingDirection == .rtl {
                    Button {
                        goNext(userInitiated: true)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Next page")
                    .disabled(!canGoNext)

                    Button {
                        goPrev(userInitiated: true)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("Previous page")
                    .disabled(pageIndex <= 0)
                } else {
                    Button {
                        goPrev(userInitiated: true)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .help("Previous page")
                    .disabled(pageIndex <= 0)

                    Button {
                        goNext(userInitiated: true)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .help("Next page")
                    .disabled(!canGoNext)
                }

                Text(pageCountText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 90, alignment: .leading)

                Divider()

                Menu {
                    Toggle("Two-page spread", isOn: $twoPageSpread)

                    Divider()

                    Picker("Fit", selection: $fitModeRaw) {
                        ForEach(ReaderFitMode.allCases) { m in
                            Text(m.title).tag(m.rawValue)
                        }
                    }

                    HStack {
                        Text("Zoom")
                        Slider(value: $zoomPercent, in: 50...200, step: 5)
                            .frame(width: 180)
                    }
                } label: {
                    Label("View", systemImage: "rectangle.3.group")
                }
                .help("Reader view options")

                HStack(spacing: 10) {
                    Toggle("Auto-advance", isOn: $autoAdvanceEnabled)
                        .toggleStyle(.switch)

                    Slider(value: $autoAdvanceSeconds, in: 2...30, step: 1)
                        .frame(width: 160)
                        .disabled(!autoAdvanceEnabled)
                        .opacity(autoAdvanceEnabled ? 1 : 0.35)

                    Text("\(Int(autoAdvanceSeconds))s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)

                    if autoAdvanceEnabled, let countdownRemaining {
                        Text("Next in \(countdownRemaining)s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.thinMaterial)
                            .clipShape(Capsule())
                            .help("Auto-advance countdown")
                    }
                }
                .help("Auto-advance to the next page after the selected delay.")

                Spacer()

                Button("Close") { dismiss() }
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
        .onChange(of: autoAdvanceSeconds) { _, _ in
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

    private var fitMode: ReaderFitMode {
        ReaderFitMode(rawValue: fitModeRaw) ?? .fit
    }

    private var step: Int { twoPageSpread ? 2 : 1 }

    private var canGoNext: Bool {
        guard !pages.isEmpty else { return false }
        return (pageIndex + step) <= pages.count - 1
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 12) {
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
                } else if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .padding(16)
                } else {
                    ProgressView()
                    .padding(20)
                }

                clickZones
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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

    private var titleText: String {
        if let profile = appModel.profileStore.profiles.first(where: { $0.id == route.profileID }) {
            return "Reader • \(profile.name)"
        }
        return "Reader"
    }

    private var pageCountText: String {
        guard !pages.isEmpty else { return "—/—" }
        return "\(pageIndex + 1)/\(pages.count)"
    }

    private func loadArchive() async {
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

        guard let profile = appModel.profileStore.profiles.first(where: { $0.id == route.profileID }) else {
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

        guard let profile = appModel.profileStore.profiles.first(where: { $0.id == route.profileID }) else {
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

        let seconds = max(2, min(30, Int(autoAdvanceSeconds.rounded())))
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
        // Arrow keys handled via `.onMoveCommand`.
        // Space: next page. Shift-space: previous page.
        // Esc: close.
        switch event.keyCode {
        case 49: // space
            if event.modifierFlags.contains(.shift) {
                goPrev(userInitiated: true)
            } else {
                goNext(userInitiated: true)
            }
        case 53: // escape
            dismiss()
        case 24, 69: // + on some keyboards, numpad +
            zoomPercent = min(200, zoomPercent + 10)
        case 27, 78: // - on some keyboards, numpad -
            zoomPercent = max(50, zoomPercent - 10)
        case 29: // 0
            zoomPercent = 100
        default:
            break
        }
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
