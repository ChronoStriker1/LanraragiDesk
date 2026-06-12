import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []

    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LanraragiDesk", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("profiles.json")
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
            profiles = [profiles[0]]
            save()
        }
    }

    func upsert(_ profile: Profile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else if profiles.isEmpty {
            profiles = [profile]
        } else {
            // Replace existing profile.
            profiles[0] = profile
        }
        save()
    }

    func delete(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        save()
        // Remove the orphaned API key; it is useless without the profile.
        try? KeychainService.delete(account: "apiKey.\(profile.id.uuidString)")
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("ProfileStore: failed to save profiles.json: %@", String(describing: error))
        }
    }
}
