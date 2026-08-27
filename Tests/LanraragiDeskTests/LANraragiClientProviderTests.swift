import Foundation
import LanraragiKit
import XCTest
@testable import LanraragiDesk

@MainActor
final class LANraragiClientProviderTests: XCTestCase {
    func testReusesClientForMatchingProfileConfiguration() async throws {
        let probe = ClientProviderProbe(credentials: ["secret"])
        let provider = makeProvider(probe: probe)
        let profile = makeProfile()

        let first = try await provider.client(for: profile)
        let second = try await provider.client(for: profile)

        XCTAssertTrue(first === second)
        XCTAssertEqual(probe.credentialReadCount, 1)
        XCTAssertEqual(probe.configurations.count, 1)
    }

    func testConfigurationChangesReplaceCachedClient() async throws {
        let probe = ClientProviderProbe(credentials: ["secret", "secret", "secret", "secret"])
        let provider = makeProvider(probe: probe)
        let profile = makeProfile()

        let original = try await provider.client(for: profile)

        var changedURL = profile
        changedURL.baseURL = URL(string: "https://other.example.test")!
        let afterURL = try await provider.client(for: changedURL)

        var changedLanguage = changedURL
        changedLanguage.language = "ja-JP"
        let afterLanguage = try await provider.client(for: changedLanguage)

        probe.maxConnections = 12
        let afterConnections = try await provider.client(for: changedLanguage)

        XCTAssertFalse(original === afterURL)
        XCTAssertFalse(afterURL === afterLanguage)
        XCTAssertFalse(afterLanguage === afterConnections)
        XCTAssertEqual(probe.configurations.map(\.maxConnectionsPerHost), [8, 8, 8, 12])
    }

    func testInvalidationReloadsCredentialAndClient() async throws {
        let probe = ClientProviderProbe(credentials: ["old-key", "new-key"])
        let provider = makeProvider(probe: probe)
        let profile = makeProfile()

        let original = try await provider.client(for: profile)
        provider.invalidate(profileID: profile.id)
        let replacement = try await provider.client(for: profile)

        XCTAssertFalse(original === replacement)
        XCTAssertEqual(
            probe.configurations.map { $0.apiKey?.rawValue },
            ["old-key", "new-key"]
        )
    }

    func testInvalidationDuringConstructionDiscardsStaleClient() async throws {
        let probe = ClientProviderProbe(credentials: ["old-key", "new-key"])
        let provider = makeProvider(probe: probe)
        let profile = makeProfile()
        probe.blockNextCredentialRead()

        let clientTask = Task.detached {
            try await provider.client(for: profile)
        }
        let credentialReadStarted = await Task.detached {
            probe.waitForBlockedCredentialRead()
        }.value

        guard credentialReadStarted else {
            probe.releaseBlockedCredentialRead()
            _ = try? await clientTask.value
            XCTFail("Timed out waiting for the credential loader")
            return
        }

        provider.invalidate(profileID: profile.id)
        probe.releaseBlockedCredentialRead()

        let returnedClient = try await clientTask.value
        let constructedClients = probe.clients

        XCTAssertEqual(
            probe.configurations.map { $0.apiKey?.rawValue },
            ["old-key", "new-key"]
        )
        XCTAssertEqual(constructedClients.count, 2)
        guard constructedClients.count == 2 else { return }
        XCTAssertFalse(returnedClient === constructedClients[0])
        XCTAssertTrue(returnedClient === constructedClients[1])
    }

    func testProfileIDsUseSeparateCacheEntries() async throws {
        let probe = ClientProviderProbe(credentials: ["first", "second"])
        let provider = makeProvider(probe: probe)
        let firstProfile = makeProfile()
        var secondProfile = makeProfile()
        secondProfile.id = UUID(uuidString: "89B6C4D4-BB48-4D31-BDF3-7977649ED4DA")!

        let first = try await provider.client(for: firstProfile)
        let second = try await provider.client(for: secondProfile)

        XCTAssertFalse(first === second)
        XCTAssertEqual(probe.credentialReadCount, 2)
        XCTAssertEqual(probe.configurations.count, 2)
    }

    func testMissingCredentialCreatesUnauthenticatedClient() async throws {
        let probe = ClientProviderProbe(credentials: [nil])
        let provider = makeProvider(probe: probe)

        _ = try await provider.client(for: makeProfile())

        XCTAssertNil(probe.configurations.first?.apiKey)
    }

    func testCredentialReadFailurePropagatesAndIsRetried() async {
        let probe = ClientProviderProbe(credentials: [])
        probe.credentialError = TestCredentialError.readFailed
        let provider = makeProvider(probe: probe)
        let profile = makeProfile()

        for _ in 0..<2 {
            do {
                _ = try await provider.client(for: profile)
                XCTFail("Expected credential read to fail")
            } catch {
                XCTAssertEqual(error as? TestCredentialError, .readFailed)
            }
        }

        XCTAssertEqual(probe.credentialReadCount, 2)
        XCTAssertTrue(probe.configurations.isEmpty)
    }

    func testConcurrentRequestsCoalesceToOneClient() async throws {
        let probe = ClientProviderProbe(credentials: ["secret"])
        let provider = makeProvider(probe: probe)
        let profile = makeProfile()

        let clients = try await withThrowingTaskGroup(of: LANraragiClient.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await provider.client(for: profile)
                }
            }

            var clients: [LANraragiClient] = []
            for try await client in group {
                clients.append(client)
            }
            return clients
        }

        let first = try XCTUnwrap(clients.first)
        XCTAssertTrue(clients.allSatisfy { $0 === first })
        XCTAssertEqual(probe.credentialReadCount, 1)
        XCTAssertEqual(probe.configurations.count, 1)
    }

    private func makeProvider(probe: ClientProviderProbe) -> LANraragiClientProvider {
        LANraragiClientProvider(
            credentialLoader: { _ in try probe.loadCredential() },
            maxConnectionsLoader: { probe.maxConnections },
            clientFactory: { configuration in probe.makeClient(configuration: configuration) }
        )
    }

    private func makeProfile() -> Profile {
        Profile(
            id: UUID(uuidString: "F92195F3-DFFD-49D2-B257-C975562D8FF8")!,
            name: "Test",
            baseURL: URL(string: "https://example.test")!,
            language: "en-US"
        )
    }
}

private enum TestCredentialError: Error, Equatable {
    case readFailed
}

private final class ClientProviderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [String?]
    private var storedCredentialReadCount = 0
    private var storedConfigurations: [LANraragiClient.Configuration] = []
    private var storedClients: [LANraragiClient] = []
    private var storedMaxConnections = 8
    private var storedCredentialError: TestCredentialError?
    private var shouldBlockNextCredentialRead = false
    private let credentialReadStarted = DispatchSemaphore(value: 0)
    private let credentialReadRelease = DispatchSemaphore(value: 0)

    init(credentials: [String?]) {
        self.credentials = credentials
    }

    var credentialReadCount: Int {
        lock.withLock { storedCredentialReadCount }
    }

    var configurations: [LANraragiClient.Configuration] {
        lock.withLock { storedConfigurations }
    }

    var clients: [LANraragiClient] {
        lock.withLock { storedClients }
    }

    var maxConnections: Int {
        get { lock.withLock { storedMaxConnections } }
        set { lock.withLock { storedMaxConnections = newValue } }
    }

    var credentialError: TestCredentialError? {
        get { lock.withLock { storedCredentialError } }
        set { lock.withLock { storedCredentialError = newValue } }
    }

    func blockNextCredentialRead() {
        lock.withLock {
            shouldBlockNextCredentialRead = true
        }
    }

    func waitForBlockedCredentialRead() -> Bool {
        switch credentialReadStarted.wait(timeout: .now() + 5) {
        case .success:
            return true
        case .timedOut:
            return false
        }
    }

    func releaseBlockedCredentialRead() {
        credentialReadRelease.signal()
    }

    func loadCredential() throws -> LANraragiAPIKey? {
        let result: (credential: LANraragiAPIKey?, shouldBlock: Bool) = try lock.withLock {
            storedCredentialReadCount += 1
            if let storedCredentialError {
                throw storedCredentialError
            }
            let value = credentials.isEmpty ? nil : credentials.removeFirst()
            let shouldBlock = shouldBlockNextCredentialRead
            shouldBlockNextCredentialRead = false
            return (value.map(LANraragiAPIKey.init), shouldBlock)
        }

        if result.shouldBlock {
            credentialReadStarted.signal()
            credentialReadRelease.wait()
        }

        return result.credential
    }

    func makeClient(configuration: LANraragiClient.Configuration) -> LANraragiClient {
        let client = LANraragiClient(configuration: configuration)
        lock.withLock {
            storedConfigurations.append(configuration)
            storedClients.append(client)
        }
        return client
    }
}
