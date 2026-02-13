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
        } catch {
            profiles = []
        }
    }

    func upsert(_ profile: Profile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    func delete(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Best-effort; surface later in UI when we add a diagnostics panel.
        }
    }
}
