import Foundation

struct ReaderRoute: Hashable, Codable {
    var profileID: UUID
    var arcid: String

    init(profileID: UUID, arcid: String) {
        self.profileID = profileID
        self.arcid = arcid
    }
}

