import SwiftUI

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

                Text("Indexing + scan UI comes next. This screen will become the Dedup Workbench.")
                    .foregroundStyle(.secondary)

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
