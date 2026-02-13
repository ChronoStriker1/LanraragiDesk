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
        .sheet(isPresented: $appModel.duplicates.showingResults) {
            if let profile = appModel.selectedProfile, let result = appModel.duplicates.result {
                DuplicateResultsView(profile: profile, result: result, thumbnails: appModel.duplicates.thumbnails)
            } else {
                ContentUnavailableView("No Results", systemImage: "square.stack.3d.up.slash")
                    .frame(minWidth: 640, minHeight: 480)
            }
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
                duplicatesCard(profile: profile)

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

    private func duplicatesCard(profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duplicate Scan")
                        .font(.headline)
                    Text("Finds likely duplicates using exact checksum matches and optional approximate cover hashing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                HStack(spacing: 10) {
                    Button("Scan") {
                        appModel.duplicates.start(profile: profile)
                    }
                    Button("Cancel", role: .destructive) {
                        appModel.duplicates.cancel()
                    }
                }
            }

            HStack(spacing: 12) {
                Toggle("Exact", isOn: $appModel.duplicates.includeExactChecksum)
                Toggle("Approx", isOn: $appModel.duplicates.includeApproximate)

                Stepper("dHash ≤ \(appModel.duplicates.dHashThreshold)", value: $appModel.duplicates.dHashThreshold, in: 0...32)
                Stepper("aHash ≤ \(appModel.duplicates.aHashThreshold)", value: $appModel.duplicates.aHashThreshold, in: 0...32)
                Stepper("Max bucket \(appModel.duplicates.bucketMaxSize)", value: $appModel.duplicates.bucketMaxSize, in: 8...512, step: 8)
            }
            .font(.caption)

            switch appModel.duplicates.status {
            case .idle:
                Text("Ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .running(let msg):
                HStack(spacing: 10) {
                    ProgressView()
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .completed(let stats):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Groups: \(appModel.duplicates.result?.groups.count ?? 0)  •  Archives scanned: \(stats.archives)  •  Time: \(String(format: "%.1fs", stats.durationSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Results") { appModel.duplicates.showingResults = true }
                }
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
