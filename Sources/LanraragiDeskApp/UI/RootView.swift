import AppKit
import SwiftUI
import LanraragiKit

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var showNotMatchesPanel: Bool = false
    @State private var section: Section = .library

    enum Section: Hashable {
        case library
        case duplicates
        case review
        case settings
        case activity
        case batch
        case plugins
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
                .padding(24)
        }
        .onAppear {
            appModel.selectFirstIfNeeded()
            if appModel.selectedProfile == nil {
                appModel.profileEditorMode = .add
            }
        }
        .sheet(item: $appModel.profileEditorMode) { mode in
            ProfileEditorView(mode: mode)
        }
        .onChange(of: appModel.duplicates.resultRevision) { _, _ in
            // Auto-focus the review UI after a scan completes.
            if case .completed = appModel.duplicates.status, appModel.duplicates.result != nil {
                section = .review
            }
            if appModel.duplicates.result == nil, section == .review {
                section = .duplicates
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let profile = appModel.selectedProfile {
            NavigationSplitView {
                sidebar(profile: profile)
            } detail: {
                detail(profile: profile)
            }
            .frame(minWidth: 980, minHeight: 640)
        } else {
            ContentUnavailableView(
                "Connect To LANraragi",
                systemImage: "server.rack",
                description: Text("Set your server address and API key to start finding duplicates.")
            )
            .frame(minWidth: 700, minHeight: 520)
        }
    }

    private func sidebar(profile: Profile) -> some View {
        List(selection: $section) {
            NavigationLink(value: Section.library) {
                Label("Library", systemImage: "books.vertical")
            }

            Divider()

            NavigationLink(value: Section.duplicates) {
                Label("Duplicates", systemImage: "rectangle.stack.badge.magnifyingglass")
            }

            // Only show Review when it's usable (after a scan produced results).
            if appModel.duplicates.result != nil {
                NavigationLink(value: Section.review) {
                    Label("Review", systemImage: "square.stack.3d.up")
                }
            }

            NavigationLink(value: Section.activity) {
                Label("Activity", systemImage: "list.bullet.rectangle")
            }

            NavigationLink(value: Section.batch) {
                Label("Batch", systemImage: "square.stack.3d.forward.dottedline")
            }

            NavigationLink(value: Section.plugins) {
                Label("Plugins", systemImage: "puzzlepiece.extension")
            }

            Divider()

            NavigationLink(value: Section.settings) {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("LanraragiDesk")
    }

    @ViewBuilder
    private func detail(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            switch section {
            case .library:
                LibraryView(profile: profile)
                    .environmentObject(appModel)
            case .duplicates:
                runCard(profile: profile)
            case .review:
                if appModel.duplicates.result != nil {
                    reviewTab(profile: profile)
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
            case .settings:
                SettingsView()
                    .environmentObject(appModel)
            case .activity:
                ActivityView()
                    .environmentObject(appModel)
            case .batch:
                BatchView()
                    .environmentObject(appModel)
            case .plugins:
                PluginsView()
                    .environmentObject(appModel)
            }

            Spacer(minLength: 0)
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
            VStack(alignment: .leading, spacing: 6) {
                Text("Find Duplicate Archives")
                    .font(.title2)
                    .bold()
                Text("Click Find Duplicates. The app will update its local index if needed, then show you likely duplicates to review and delete manually.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    section = .duplicates
                    appModel.duplicates.start(profile: profile)
                } label: {
                    Text("Find Duplicates")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel", role: .destructive) { appModel.duplicates.cancel() }

                Spacer()
            }

            statusBlock

            DisclosureGroup("Advanced") {
                advancedOptions(profile: profile)
                    .padding(.top, 8)
            }
            .font(.callout)
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .debugFrameNumber(1)
    }

    @ViewBuilder
    private var statusBlock: some View {
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
                    Button("Go To Review") { section = .review }
                }
            case .failed(let msg):
                Text("Failed: \(msg)")
                    .font(.callout)
                .foregroundStyle(.red)
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
