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
        let invalidationGeneration: UInt64
    }

    private struct CachedClient: Sendable {
        let fingerprint: ConfigurationFingerprint
        let client: LANraragiClient
    }

    private let credentialLoader: CredentialLoader
    private let maxConnectionsLoader: MaxConnectionsLoader
    private let clientFactory: ClientFactory
    nonisolated private let invalidationGenerations = ClientProviderInvalidationGenerations()
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
        while true {
            let invalidationGeneration = invalidationGenerations.current(for: profile.id)
            let fingerprint = ConfigurationFingerprint(
                baseURL: profile.baseURL,
                acceptLanguage: profile.language,
                maxConnectionsPerHost: maxConnectionsLoader(),
                invalidationGeneration: invalidationGeneration
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

            // invalidate(profileID:) is nonisolated so profile saves can advance
            // this generation from another thread while a synchronous loader or
            // factory is still running inside the actor. Discard that stale client.
            guard invalidationGenerations.current(for: profile.id) == invalidationGeneration else {
                continue
            }

            clientsByProfileID[profile.id] = CachedClient(
                fingerprint: fingerprint,
                client: client
            )
            return client
        }
    }

    nonisolated func invalidate(profileID: Profile.ID) {
        invalidationGenerations.advance(for: profileID)
    }
}

private final class ClientProviderInvalidationGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var generationsByProfileID: [Profile.ID: UInt64] = [:]

    func current(for profileID: Profile.ID) -> UInt64 {
        lock.withLock {
            generationsByProfileID[profileID, default: 0]
        }
    }

    func advance(for profileID: Profile.ID) {
        lock.withLock {
            generationsByProfileID[profileID] = currentValue(for: profileID) &+ 1
        }
    }

    private func currentValue(for profileID: Profile.ID) -> UInt64 {
        generationsByProfileID[profileID, default: 0]
    }
}
