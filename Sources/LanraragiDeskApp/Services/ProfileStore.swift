import Foundation

enum ProfileUpsertResult: Equatable {
    case inserted
    case updated
    case rejectedMismatchedID(existingID: UUID)
}

protocol ProfileCredentialStoring {
    func deleteAPIKey(for profileID: UUID) throws
}

struct KeychainProfileCredentialStore: ProfileCredentialStoring {
    func deleteAPIKey(for profileID: UUID) throws {
        try KeychainService.delete(account: "apiKey.\(profileID.uuidString)")
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []

    private let fileURL: URL
    private let credentialStore: any ProfileCredentialStoring

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LanraragiDesk", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("profiles.json")
        self.credentialStore = KeychainProfileCredentialStore()
        load()
    }

    init(fileURL: URL, credentialStore: any ProfileCredentialStoring) {
        self.fileURL = fileURL
        self.credentialStore = credentialStore
        load()
    }

    func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try JSONDecoder().decode([Profile].self, from: data)
        } catch let error as DecodingError {
            // Keep the broken file around instead of silently wiping the profile;
            // its keychain entry would otherwise be stranded under an unknown UUID.
            let backupURL = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            NSLog("ProfileStore: failed to decode profiles.json (%@); backed up to %@", String(describing: error), backupURL.path)
            profiles = []
        } catch {
            profiles = []
        }

        // This app is single-profile by design: keep only the first.
        if profiles.count > 1 {
            let loadedProfiles = profiles
            let discardedProfiles = profiles.dropFirst()
            profiles = [profiles[0]]
            do {
                try save()
                for profile in discardedProfiles {
                    try? credentialStore.deleteAPIKey(for: profile.id)
                }
            } catch {
                profiles = loadedProfiles
                NSLog("ProfileStore: failed to persist single-profile cleanup: %@", String(describing: error))
            }
        }
    }

    @discardableResult
    func upsert(_ profile: Profile) throws -> ProfileUpsertResult {
        let previousProfiles = profiles
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            do {
                try save()
                return .updated
            } catch {
                profiles = previousProfiles
                throw error
            }
        } else if profiles.isEmpty {
            profiles = [profile]
            do {
                try save()
                return .inserted
            } catch {
                profiles = previousProfiles
                throw error
            }
        } else {
            let existingID = profiles[0].id
            NSLog(
                "ProfileStore: rejected replacement profile %@ because existing profile uses %@",
                profile.id.uuidString,
                existingID.uuidString
            )
            return .rejectedMismatchedID(existingID: existingID)
        }
    }

    func canUpsert(profileID: UUID) -> Bool {
        profiles.isEmpty || profiles.contains { $0.id == profileID }
    }

    func delete(_ profile: Profile) {
        let previousProfiles = profiles
        profiles.removeAll { $0.id == profile.id }
        do {
            try save()
        } catch {
            profiles = previousProfiles
            NSLog("ProfileStore: failed to delete profile: %@", String(describing: error))
            return
        }
        // Remove the orphaned API key; it is useless without the profile.
        try? credentialStore.deleteAPIKey(for: profile.id)
    }

    private func save() throws {
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: fileURL, options: [.atomic])
    }
}
