import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var tagMinWeight: Int = 2
    @State private var tagTTLHours: Int = 24
    @State private var tagRefreshStatus: String?

    @AppStorage("reader.readingDirection") private var readingDirectionRaw: String = ReaderDirection.ltr.rawValue

    var body: some View {
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

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear {
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
}
