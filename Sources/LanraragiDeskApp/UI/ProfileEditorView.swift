import SwiftUI

struct ProfileEditorView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let mode: ProfileEditorMode

    @State private var name: String = ""
    @State private var baseURLString: String = ""
    @State private var language: String = "en-US"
    @State private var apiKey: String = ""

    init(mode: ProfileEditorMode) {
        self.mode = mode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title).bold()

            Form {
                TextField("Name", text: $name)
                TextField("Base URL", text: $baseURLString)
                    .textContentType(.URL)
                TextField("Language", text: $language)
                SecureField("API Key (stored in Keychain)", text: $apiKey)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
        .onAppear { loadInitial() }
    }

    private var title: String {
        switch mode {
        case .add: return "Add Profile"
        case .edit: return "Edit Profile"
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalizedBaseURL != nil
    }

    private func loadInitial() {
        switch mode {
        case .add:
            name = "LANraragi"
            baseURLString = "http://127.0.0.1:3000"
            language = "en-US"
            apiKey = ""
        case .edit(let profile):
            name = profile.name
            baseURLString = profile.baseURL.absoluteString
            language = profile.language
            apiKey = "" // never prefill secrets
        }
    }

    private func save() {
        guard let url = normalizedBaseURL else { return }

        let profile: Profile
        switch mode {
        case .add:
            profile = Profile(name: name, baseURL: url, language: language)
        case .edit(let existing):
            profile = Profile(id: existing.id, name: name, baseURL: url, language: language)
        }

        appModel.profileStore.upsert(profile)
        appModel.selectedProfileID = profile.id

        if !apiKey.isEmpty {
            try? KeychainService.setString(apiKey, account: "apiKey.\(profile.id.uuidString)")
        }
    }

    private var normalizedBaseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard components.host != nil else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url
    }
}
