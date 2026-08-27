import SwiftUI

struct ProfileEditorView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let mode: ProfileEditorMode

    @State private var name: String = ""
    @State private var baseURLString: String = ""
    @State private var language: String = "en-US"
    @State private var apiKey: String = ""
    @State private var saveError: String?

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

            if let saveError {
                Text(saveError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if save() {
                        dismiss()
                    }
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

    private func save() -> Bool {
        guard let url = normalizedBaseURL else { return false }

        let profile: Profile
        switch mode {
        case .add:
            profile = Profile(name: name, baseURL: url, language: language)
        case .edit(let existing):
            profile = Profile(id: existing.id, name: name, baseURL: url, language: language)
        }

        guard appModel.profileStore.canUpsert(profileID: profile.id) else {
            saveError = "Another profile already exists. Only one profile is supported."
            return false
        }

        let keychainAccount = "apiKey.\(profile.id.uuidString)"
        var previousAPIKey: String?
        if !apiKey.isEmpty {
            do {
                previousAPIKey = try KeychainService.getString(account: keychainAccount)
                try KeychainService.setString(apiKey, account: keychainAccount)
            } catch {
                saveError = "Could not save the API key to the Keychain (\(error)). Profile not saved."
                return false
            }
        }

        do {
            if case .rejectedMismatchedID = try appModel.profileStore.upsert(profile) {
                restoreAPIKey(previousAPIKey, account: keychainAccount)
                saveError = "Another profile already exists. Profile not saved."
                return false
            }
        } catch {
            restoreAPIKey(previousAPIKey, account: keychainAccount)
            saveError = "Could not save the profile (\(error))."
            return false
        }
        appModel.selectedProfileID = profile.id

        // Cached clients hold the old base URL/API key; drop them.
        appModel.invalidateClients(profileID: profile.id)
        return true
    }

    private func restoreAPIKey(_ previousAPIKey: String?, account: String) {
        guard !apiKey.isEmpty else { return }
        if let previousAPIKey {
            try? KeychainService.setString(previousAPIKey, account: account)
        } else {
            try? KeychainService.delete(account: account)
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
