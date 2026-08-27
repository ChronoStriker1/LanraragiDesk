import Foundation
import LanraragiKit

enum APIKeyCredential {
    enum CredentialError: Error, Equatable {
        case missing
    }

    static func load(
        profileID: UUID,
        read: (String) throws -> String? = { account in
            try KeychainService.getString(account: account)
        }
    ) throws -> LANraragiAPIKey {
        let account = "apiKey.\(profileID.uuidString)"
        guard let value = try read(account) else {
            throw CredentialError.missing
        }
        return LANraragiAPIKey(value)
    }
}
