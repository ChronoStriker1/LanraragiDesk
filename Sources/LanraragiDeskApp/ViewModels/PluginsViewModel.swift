import Foundation
import LanraragiKit

@MainActor
final class PluginsViewModel: ObservableObject {
    @Published private(set) var plugins: [PluginInfo] = []
    @Published private(set) var statusText: String?
    @Published private(set) var isLoading: Bool = false

    func load(profile: Profile) async {
        isLoading = true
        statusText = "Loading plugins…"
        defer { isLoading = false }

        do {
            let account = "apiKey.\(profile.id.uuidString)"
            let apiKeyString = try KeychainService.getString(account: account)
            let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

            let client = LANraragiClient(configuration: .init(
                baseURL: profile.baseURL,
                apiKey: apiKey,
                acceptLanguage: profile.language,
                maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
            ))

            plugins = try await client.listPlugins()
            statusText = plugins.isEmpty ? "No plugins found." : "Loaded \(plugins.count) plugins."
        } catch {
            statusText = "Failed: \(ErrorPresenter.short(error))"
        }
    }

    func queue(profile: Profile, pluginID: String, arcid: String, arg: String?) async throws -> MinionJob {
        let account = "apiKey.\(profile.id.uuidString)"
        let apiKeyString = try KeychainService.getString(account: account)
        let apiKey = apiKeyString.map { LANraragiAPIKey($0) }

        let client = LANraragiClient(configuration: .init(
            baseURL: profile.baseURL,
            apiKey: apiKey,
            acceptLanguage: profile.language,
            maxConnectionsPerHost: AppSettings.maxConnectionsPerHost(defaultValue: 8)
        ))

        return try await client.queuePlugin(pluginID: pluginID, arcid: arcid, arg: arg)
    }
}
