import SwiftUI

struct SettingsView: View {
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

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

