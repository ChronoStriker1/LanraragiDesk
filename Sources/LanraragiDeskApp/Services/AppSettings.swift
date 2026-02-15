import Foundation

enum AppSettings {
    // Networking is intentionally conservative by default so the app doesn't
    // monopolize the machine during large-library operations.
    static let maxConnectionsKey = "network.maxConnectionsPerHost"

    static func maxConnectionsPerHost(defaultValue: Int = 8) -> Int {
        let v = UserDefaults.standard.integer(forKey: maxConnectionsKey)
        // `integer(forKey:)` returns 0 if unset.
        let clamped = max(1, min(32, v == 0 ? defaultValue : v))
        return clamped
    }
}
