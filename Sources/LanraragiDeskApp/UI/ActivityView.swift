import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var appModel: AppModel

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Activity")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Clear", role: .destructive) {
                    appModel.activity.clear()
                }
            }

            if appModel.activity.events.isEmpty {
                ContentUnavailableView("No Activity Yet", systemImage: "list.bullet.rectangle", description: Text("Edits, scans, and server actions will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                List {
                    ForEach(appModel.activity.events) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(e.title)
                                    .font(.callout)
                                Spacer()
                                Text(Self.formatter.string(from: e.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let d = e.detail, !d.isEmpty {
                                Text(d)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

