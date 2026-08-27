import Foundation
import LanraragiKit

/// Reuses `LANraragiClient` instances for request-heavy paths without allowing
/// a profile's networking configuration to drift from the cached client. API
/// key changes must call `invalidate(profileID:)`; secrets are deliberately not
/// read on every request just to build a fingerprint.
actor LANraragiClientProvider {
    typealias CredentialLoader = @Sendable (Profile.ID) throws -> LANraragiAPIKey?
    typealias MaxConnectionsLoader = @Sendable () -> Int
    typealias ClientFactory = @Sendable (LANraragiClient.Configuration) -> LANraragiClient

    static let shared = LANraragiClientProvider()

    private struct ConfigurationFingerprint: Equatable, Sendable {
        let baseURL: URL
        let acceptLanguage: String
        let maxConnectionsPerHost: Int
    }

    private struct CachedClient: Sendable {
        let fingerprint: ConfigurationFingerprint
        let client: LANraragiClient
    }

    private let credentialLoader: CredentialLoader
    private let maxConnectionsLoader: MaxConnectionsLoader
    private let clientFactory: ClientFactory
    private var clientsByProfileID: [Profile.ID: CachedClient] = [:]

    init(
        credentialLoader: @escaping CredentialLoader = { profileID in
            let account = "apiKey.\(profileID.uuidString)"
            return try KeychainService.getString(account: account).map(LANraragiAPIKey.init)
        },
        maxConnectionsLoader: @escaping MaxConnectionsLoader = {
            AppSettings.maxConnectionsPerHost(defaultValue: 8)
        },
        clientFactory: @escaping ClientFactory = { configuration in
            LANraragiClient(configuration: configuration)
        }
    ) {
        self.credentialLoader = credentialLoader
        self.maxConnectionsLoader = maxConnectionsLoader
        self.clientFactory = clientFactory
    }

    func client(for profile: Profile) throws -> LANraragiClient {
        let fingerprint = ConfigurationFingerprint(
            baseURL: profile.baseURL,
            acceptLanguage: profile.language,
            maxConnectionsPerHost: maxConnectionsLoader()
        )

        if let cached = clientsByProfileID[profile.id], cached.fingerprint == fingerprint {
            return cached.client
        }

        // A missing credential is a valid unauthenticated configuration. Actual
        // Keychain read failures are allowed to propagate and are never cached.
        let apiKey = try credentialLoader(profile.id)
        let client = clientFactory(.init(
            baseURL: fingerprint.baseURL,
            apiKey: apiKey,
            acceptLanguage: fingerprint.acceptLanguage,
            maxConnectionsPerHost: fingerprint.maxConnectionsPerHost
        ))
        clientsByProfileID[profile.id] = CachedClient(
            fingerprint: fingerprint,
            client: client
        )
        return client
    }

    func invalidate(profileID: Profile.ID) {
        clientsByProfileID[profileID] = nil
    }
}
