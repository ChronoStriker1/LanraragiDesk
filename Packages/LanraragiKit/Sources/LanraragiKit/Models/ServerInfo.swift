import Foundation

public struct ServerInfo: Decodable, Sendable, Equatable {
    public var version: String?

    // Common LANraragi fields (best-effort; all optional so we don't break on changes)
    public var name: String?
    public var api_version: Int?
    public var server_tracks_progress: Bool?

    // Some deployments may include additional fields we don't care about yet.
    private enum CodingKeys: String, CodingKey {
        case version
        case name
        case api_version
        case server_tracks_progress
    }
}
