import SwiftUI

struct ConnectionHeaderCard: View {
    @EnvironmentObject private var appModel: AppModel

    let profile: Profile

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image("AppHero")
                .resizable()
                .scaledToFill()
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.black, lineWidth: 2)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("LanraragiDesk")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(profile.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    Button(appModel.connectionStatus == .testing ? "Testing…" : "Test Connection") {
                        Task { await appModel.testConnection() }
                    }
                    .disabled(appModel.connectionStatus == .testing)

                    Button("Connection…") {
                        appModel.profileEditorMode = .edit(profile)
                    }
                }

                ConnectionStatusPill(status: appModel.connectionStatus)
            }
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ConnectionStatusPill: View {
    let status: AppModel.ConnectionStatus

    var body: some View {
        Group {
            switch status {
            case .idle:
                pill(text: "Not tested", color: .gray)
            case .testing:
                pill(text: "Testing", color: .blue)
            case .ok(let info):
                pill(text: "OK\(info.version.map { " • v\($0)" } ?? "")", color: .green)
            case .unauthorized:
                pill(text: "Unauthorized", color: .orange)
            case .failed:
                pill(text: "Failed", color: .red)
            }
        }
        .font(.caption)
    }

    private func pill(text: String, color: Color) -> some View {
        Text(text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

