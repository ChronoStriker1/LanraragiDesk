import AppKit
import SwiftUI
import LanraragiKit

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var editingProfile: Profile?
    @State private var showingSetup = false
    @State private var tab: Tab = .scan

    enum Tab: Hashable {
        case scan
        case review
        case notMatch
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
                showingSetup = true
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(mode: .edit(profile))
        }
        .sheet(isPresented: $showingSetup) {
            ProfileEditorView(mode: .add)
        }
        .onChange(of: appModel.duplicates.resultRevision) { _, _ in
            // Auto-focus the review UI after a scan completes.
            tab = .review
        }
    }

    @ViewBuilder
    private var content: some View {
        if let profile = appModel.selectedProfile {
            VStack(alignment: .leading, spacing: 18) {
                if tab == .scan {
                    header(profile: profile)
                }
                tabs(profile: profile)
                Spacer()
            }
            .frame(minWidth: 900, minHeight: 620, alignment: .topLeading)
        } else {
            ContentUnavailableView(
                "Connect To LANraragi",
                systemImage: "server.rack",
                description: Text("Set your server address and API key to start finding duplicates.")
            )
            .frame(minWidth: 700, minHeight: 520)
        }
    }

    private func tabs(profile: Profile) -> some View {
        TabView(selection: $tab) {
            VStack(alignment: .leading, spacing: 0) {
                runCard(profile: profile)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .tag(Tab.scan)
                .tabItem { Label("Scan", systemImage: "magnifyingglass") }

            reviewTab(profile: profile)
                .tag(Tab.review)
                .tabItem { Label("Review", systemImage: "square.stack.3d.up") }

            NotMatchesView(profile: profile)
                .environmentObject(appModel)
                .tag(Tab.notMatch)
                .tabItem { Label("Not a match", systemImage: "nosign") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func header(profile: Profile) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LanraragiDesk")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(profile.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                Button(appModel.connectionStatus == .testing ? "Testing…" : "Test Connection") {
                    Task { await appModel.testConnection() }
                }
                .disabled(appModel.connectionStatus == .testing)

                connectionPill

                Button("Connection…") {
                    editingProfile = profile
                }
            }
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func runCard(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Find Duplicate Archives")
                    .font(.title2)
                    .bold()
                Text("Click scan. The app will update its local index if needed, then show you likely duplicates to review and delete manually.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    appModel.duplicates.start(profile: profile)
                } label: {
                    Text("Scan For Duplicates")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel", role: .destructive) { appModel.duplicates.cancel() }

                Spacer()

                Button("Reset Index", role: .destructive) { appModel.indexing.resetIndexFiles() }
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
                    Button("Go To Review") { tab = .review }
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

    private var connectionPill: some View {
        Group {
            switch appModel.connectionStatus {
            case .idle:
                Text("Not tested")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.gray.opacity(0.15))
                    .clipShape(Capsule())
            case .testing:
                Text("Testing")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.blue.opacity(0.15))
                    .clipShape(Capsule())
            case .ok(let info):
                Text("OK\(info.version.map { " • v\($0)" } ?? "")")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.green.opacity(0.15))
                    .clipShape(Capsule())
            case .unauthorized:
                Text("Unauthorized")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.15))
                    .clipShape(Capsule())
            case .failed:
                Text("Failed")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .font(.caption)
    }
}
