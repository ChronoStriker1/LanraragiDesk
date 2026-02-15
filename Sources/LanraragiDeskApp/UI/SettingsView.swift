import SwiftUI
import LanraragiKit

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var tagMinWeight: Int = 2
    @State private var tagTTLHours: Int = 24
    @State private var tagRefreshStatus: String?
    @State private var thumbsJobStatus: String?
    @State private var forceThumbs: Bool = false
    @State private var maxConnectionsPerHost: Int = 8

    @AppStorage("reader.readingDirection") private var readingDirectionRaw: String = ReaderDirection.ltr.rawValue
    @AppStorage("debug.showFrameNumbers") private var showFrameNumbers: Bool = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                if let profile = appModel.selectedProfile {
                    ConnectionHeaderCard(profile: profile)
                        .environmentObject(appModel)
                }

                settingsCard
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.visible)
        .onAppear {
            maxConnectionsPerHost = AppSettings.maxConnectionsPerHost(defaultValue: 8)
            tagMinWeight = UserDefaults.standard.integer(forKey: "tags.minWeight")
            if tagMinWeight == 0 {
                // A bit of signal by default without being too strict.
                tagMinWeight = 2
            }
            let ttl = UserDefaults.standard.integer(forKey: "tags.ttlHours")
            tagTTLHours = ttl > 0 ? ttl : 24
        }
        .onChange(of: tagMinWeight) { _, v in
            UserDefaults.standard.set(v, forKey: "tags.minWeight")
        }
        .onChange(of: tagTTLHours) { _, v in
            UserDefaults.standard.set(v, forKey: "tags.ttlHours")
        }
        .onChange(of: maxConnectionsPerHost) { _, v in
            UserDefaults.standard.set(max(1, min(32, v)), forKey: AppSettings.maxConnectionsKey)
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings")
                    .font(.title2)
                    .bold()
                Text("Customize reading behavior and app defaults.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            GroupBox("UI labels") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show region numbers", isOn: $showFrameNumbers)
                        .font(.callout)
                    Text("Adds numbered overlays to key panels so you can refer to specific areas when requesting changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .debugFrameNumber(1)

            GroupBox("Reader") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Reading direction")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $readingDirectionRaw) {
                        ForEach(ReaderDirection.allCases) { d in
                            Text(d.title).tag(d.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)

                    Text("This swaps the on-screen Next/Previous buttons and arrow-key behavior. Page numbers still increase normally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .debugFrameNumber(2)

            GroupBox("Performance") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Control how aggressively the app talks to your server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Stepper("Max connections: \(maxConnectionsPerHost)", value: $maxConnectionsPerHost, in: 1...32)
                            .frame(width: 220, alignment: .leading)
                        Spacer()
                    }

                    Text("Lower this if scans make your Mac feel slow or your server struggles. Higher can speed up scans on fast servers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }
            .debugFrameNumber(3)

            GroupBox("Tag suggestions") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("The app can fetch popular tags from your server to power autocomplete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Stepper("Min weight: \(tagMinWeight)", value: $tagMinWeight, in: 0...999)
                            .frame(width: 180, alignment: .leading)
                        Stepper("TTL: \(tagTTLHours)h", value: $tagTTLHours, in: 1...168)
                            .frame(width: 140, alignment: .leading)
                        Spacer()
                        Button("Refresh Now") {
                            Task { await refreshTagStats() }
                        }
                    }

                    if let tagRefreshStatus {
                        Text(tagRefreshStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .debugFrameNumber(4)

            GroupBox("Server actions") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Force thumbnail regeneration", isOn: $forceThumbs)
                        .font(.callout)

                    HStack {
                        Button("Regenerate Thumbnails") {
                            Task { await regenThumbs() }
                        }
                        .disabled(appModel.selectedProfile == nil)

                        Spacer()
                    }

                    if let thumbsJobStatus {
                        Text(thumbsJobStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
            .debugFrameNumber(5)

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func refreshTagStats() async {
        guard let profile = appModel.selectedProfile else {
            tagRefreshStatus = "No profile selected."
            return
        }

        tagRefreshStatus = "Refreshing…"
        do {
            try await appModel.tagSuggestions.refresh(
                profile: profile,
                settings: .init(minWeight: tagMinWeight, ttlSeconds: tagTTLHours * 60 * 60)
            )
            tagRefreshStatus = "Updated tag suggestions."
            appModel.activity.add(.init(kind: .action, title: "Refreshed tag suggestions"))
        } catch {
            tagRefreshStatus = "Failed: \(error)"
            appModel.activity.add(.init(kind: .error, title: "Tag suggestions refresh failed", detail: String(describing: error)))
        }
    }

    private func regenThumbs() async {
        guard let profile = appModel.selectedProfile else {
            thumbsJobStatus = "No profile selected."
            return
        }

        thumbsJobStatus = "Starting thumbnail regeneration…"
        do {
            let account = "apiKey.\(profile.id.uuidString)"
            let apiKeyString = try KeychainService.getString(account: account)
            let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

            let client = LANraragiClient(configuration: .init(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                acceptLanguage: profile.language,
                maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
            ))

            let job = try await client.regenerateThumbnails(force: forceThumbs)
            thumbsJobStatus = "Minion job started: \(job.job)"
            appModel.activity.add(.init(kind: .action, title: "Thumbnail regeneration started", detail: "job \(job.job)"))
        } catch {
            thumbsJobStatus = "Failed: \(error)"
            appModel.activity.add(.init(kind: .error, title: "Thumbnail regeneration failed", detail: String(describing: error)))
        }
    }
}
