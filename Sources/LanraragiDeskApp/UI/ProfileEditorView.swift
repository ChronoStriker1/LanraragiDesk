import SwiftUI

struct ProfileEditorView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    let mode: ProfileEditorMode

    @State private var name: String = ""
    @State private var baseURLString: String = ""
    @State private var language: String = "en-US"
    @State private var apiKey: String = ""
    @State private var shouldClearAPIKey: Bool = false
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
                HStack {
                    SecureField("New API Key (leave blank to keep stored key)", text: $apiKey)
                        .disabled(shouldClearAPIKey)

                    if case .edit = mode {
                        if shouldClearAPIKey {
                            Button("Keep Stored Key") {
                                shouldClearAPIKey = false
                            }
                        } else {
                            Button("Clear Stored Key", role: .destructive) {
                                apiKey = ""
                                shouldClearAPIKey = true
                            }
                        }
                    }
                }

                if shouldClearAPIKey {
                    Text("The stored API key will be removed when you save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            shouldClearAPIKey = false
        case .edit(let profile):
            name = profile.name
            baseURLString = profile.baseURL.absoluteString
            language = profile.language
            apiKey = "" // never prefill secrets
            shouldClearAPIKey = false
        }
    }

    private func save() -> Bool {
        guard let url = normalizedBaseURL else { return false }
        saveError = nil

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
        let shouldChangeAPIKey = shouldClearAPIKey || !apiKey.isEmpty
        if shouldChangeAPIKey {
            do {
                previousAPIKey = try KeychainService.getString(account: keychainAccount)
                if shouldClearAPIKey {
                    try KeychainService.delete(account: keychainAccount)
                } else {
                    try KeychainService.setString(apiKey, account: keychainAccount)
                }
            } catch {
                let action = shouldClearAPIKey ? "clear" : "save"
                saveError = "Could not \(action) the API key in the Keychain (\(error)). Profile not saved."
                return false
            }
        }

        do {
            if case .rejectedMismatchedID = try appModel.profileStore.upsert(profile) {
                restoreAPIKey(previousAPIKey, account: keychainAccount, ifChanged: shouldChangeAPIKey)
                saveError = "Another profile already exists. Profile not saved."
                return false
            }
        } catch {
            restoreAPIKey(previousAPIKey, account: keychainAccount, ifChanged: shouldChangeAPIKey)
            saveError = "Could not save the profile (\(error))."
            return false
        }
        appModel.selectedProfileID = profile.id

        // Cached clients hold the old base URL/API key; drop them.
        appModel.invalidateClients(profileID: profile.id)
        return true
    }

    private func restoreAPIKey(_ previousAPIKey: String?, account: String, ifChanged: Bool) {
        guard ifChanged else { return }
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
