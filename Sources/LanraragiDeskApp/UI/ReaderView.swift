import AppKit
import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let route: ReaderRoute

    @AppStorage("reader.autoAdvanceEnabled") private var autoAdvanceEnabled: Bool = false
    @AppStorage("reader.autoAdvanceSeconds") private var autoAdvanceSeconds: Double = 8
    @AppStorage("reader.readingDirection") private var readingDirectionRaw: String = ReaderDirection.ltr.rawValue

    @State private var pages: [URL] = []
    @State private var pageIndex: Int = 0

    @State private var image: NSImage?
    @State private var errorText: String?

    @State private var countdownRemaining: Int?
    @State private var timerTask: Task<Void, Never>?
    @State private var loadTask: Task<Void, Never>?

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
                    .disabled(pageIndex >= max(0, pages.count - 1))

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
                    .disabled(pageIndex >= max(0, pages.count - 1))
                }

                Text(pageCountText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 90, alignment: .leading)

                Divider()

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
        }
    }

    private var readingDirection: ReaderDirection {
        ReaderDirection(rawValue: readingDirectionRaw) ?? .ltr
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.thinMaterial)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
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
        errorText = nil
        countdownRemaining = nil
        timerTask?.cancel()
        loadTask?.cancel()

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
        errorText = nil

        guard let profile = appModel.profileStore.profiles.first(where: { $0.id == route.profileID }) else {
            errorText = "Profile not found"
            return
        }
        guard pageIndex >= 0, pageIndex < pages.count else {
            errorText = "Missing page"
            return
        }
        let url = pages[pageIndex]

        loadTask = Task {
            do {
                let bytes = try await appModel.archives.bytes(profile: profile, url: url)
                let img = await MainActor.run { ImageDownsampler.thumbnail(from: bytes, maxPixelSize: 2200) }
                if Task.isCancelled { return }
                if let img {
                    self.image = img
                } else {
                    self.errorText = "Decode failed"
                }
            } catch {
                if Task.isCancelled { return }
                self.errorText = ErrorPresenter.short(error)
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
        guard pageIndex < pages.count - 1 else {
            if autoAdvanceEnabled {
                autoAdvanceEnabled = false
            }
            return
        }
        pageIndex += 1
    }

    private func goPrev(userInitiated: Bool) {
        if userInitiated {
            restartAutoAdvance(reason: .userInteraction)
        }
        guard pageIndex > 0 else { return }
        pageIndex -= 1
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
        default:
            break
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
