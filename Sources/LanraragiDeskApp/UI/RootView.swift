import SwiftUI
import LanraragiKit

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var showingAddProfile = false
    @State private var editingProfile: Profile?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            appModel.selectFirstIfNeeded()
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(mode: .edit(profile))
        }
        .sheet(isPresented: $showingAddProfile) {
            ProfileEditorView(mode: .add)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            List(selection: $appModel.selectedProfileID) {
                Section("Profiles") {
                    ForEach(appModel.profileStore.profiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.headline)
                            Text(profile.baseURL.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contextMenu {
                            Button("Edit") { editingProfile = profile }
                            Button("Delete", role: .destructive) {
                                try? KeychainService.delete(account: "apiKey.\(profile.id.uuidString)")
                                appModel.profileStore.delete(profile)
                                appModel.selectedProfileID = appModel.profileStore.profiles.first?.id
                            }
                        }
                        .tag(profile.id)
                    }
                }
            }

            HStack {
                Button("Add Profile") { showingAddProfile = true }
                Spacer()
                if let profile = appModel.selectedProfile {
                    Button("Edit") { editingProfile = profile }
                }
            }
            .padding([.horizontal, .bottom])
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let profile = appModel.selectedProfile {
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.largeTitle).bold()
                    Text(profile.baseURL.absoluteString).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await appModel.testConnection() }
                    } label: {
                        Text(appModel.connectionStatus == .testing ? "Testing…" : "Test Connection")
                    }
                    .disabled(appModel.connectionStatus == .testing)

                    connectionPill

                    Spacer()
                }

                Divider()

                Text("Deduplicator")
                    .font(.title2)
                    .bold()

                indexingCard(profile: profile)

                Spacer()
            } else {
                ContentUnavailableView(
                    "No Profile",
                    systemImage: "server.rack",
                    description: Text("Add a LANraragi profile to begin.")
                )
            }
        }
        .padding(24)
    }

    private func indexingCard(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fingerprint Index")
                        .font(.headline)
                    Text("Builds a local cover fingerprint database so later duplicate scans don’t do O(n²) comparisons.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    Button("Start Index") {
                        appModel.indexing.start(profile: profile)
                    }
                    Button("Cancel", role: .destructive) {
                        appModel.indexing.cancel()
                    }
                }
            }

            switch appModel.indexing.status {
            case .idle:
                Text("Ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .running(let p):
                progressView(p)
            case .completed(let p):
                progressView(p)
            case .failed(let msg):
                Text("Failed: \(msg)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func progressView(_ p: IndexerProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let total = max(1, p.total)
            let current = min(total, p.startOffset + p.seen)
            ProgressView(value: Double(current), total: Double(total)) {
                Text(phaseText(p.phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Text("Seen: \(p.seen)")
                Text("Indexed: \(p.indexed)")
                Text("Skipped: \(p.skipped)")
                Text("Failed: \(p.failed)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let arcid = p.currentArcid, !arcid.isEmpty {
                Text("Current: \(arcid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func phaseText(_ phase: IndexerProgress.Phase) -> String {
        switch phase {
        case .starting:
            return "Starting"
        case .enumerating(let total):
            return "Enumerating (\(total) total)"
        case .indexing(let total):
            return "Indexing (\(total) total)"
        case .completed(let total):
            return "Completed (\(total) total)"
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
