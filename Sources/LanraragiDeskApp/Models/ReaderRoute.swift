import Foundation
import LanraragiKit

struct TankoubonReaderContext: Hashable, Codable {
    let tankID: String
    let name: String
    let archives: [String]
    let archiveTitles: [String: String]

    init(
        tankID: String,
        name: String,
        archives: [String],
        archiveTitles: [String: String] = [:]
    ) {
        self.tankID = tankID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmedName.isEmpty ? "Tankoubon" : trimmedName
        self.archives = Self.orderedUniqueArchives(archives)
        self.archiveTitles = Self.normalizedTitles(
            archiveTitles,
            validArchives: Set(self.archives)
        )
    }

    init(tankoubon: Tankoubon) {
        self.init(
            tankID: tankoubon.id,
            name: tankoubon.name,
            archives: tankoubon.archives,
            archiveTitles: (tankoubon.fullData ?? []).reduce(into: [:]) { titles, metadata in
                guard let title = metadata.title else { return }
                titles[metadata.arcid] = title
            }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case tankID
        case name
        case archives
        case archiveTitles
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedArchives = Self.orderedUniqueArchives(
            try container.decode([String].self, forKey: .archives)
        )
        let decodedTankID = try container.decode(String.self, forKey: .tankID)
        let decodedName = try container.decode(String.self, forKey: .name)
        tankID = decodedTankID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = decodedName.trimmingCharacters(in: .whitespacesAndNewlines)
        name = trimmedName.isEmpty ? "Tankoubon" : trimmedName
        archives = decodedArchives
        archiveTitles = Self.normalizedTitles(
            try container.decodeIfPresent([String: String].self, forKey: .archiveTitles) ?? [:],
            validArchives: Set(decodedArchives)
        )
    }

    private static func orderedUniqueArchives(_ archives: [String]) -> [String] {
        var seen: Set<String> = []
        return archives.compactMap { rawArcid in
            let arcid = rawArcid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !arcid.isEmpty, seen.insert(arcid).inserted else { return nil }
            return arcid
        }
    }

    private static func normalizedTitles(
        _ titles: [String: String],
        validArchives: Set<String>
    ) -> [String: String] {
        titles.reduce(into: [:]) { result, pair in
            let arcid = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validArchives.contains(arcid), !title.isEmpty else { return }
            result[arcid] = title
        }
    }

    func displayTitle(for arcid: String, position: Int) -> String {
        archiveTitles[arcid] ?? "Archive \(position)"
    }

    func index(of arcid: String) -> Int? {
        archives.firstIndex(of: arcid)
    }

    func archiveBefore(_ arcid: String) -> String? {
        guard let index = index(of: arcid), index > 0 else { return nil }
        return archives[index - 1]
    }

    func archiveAfter(_ arcid: String) -> String? {
        guard let index = index(of: arcid), index + 1 < archives.count else { return nil }
        return archives[index + 1]
    }

    func readerRoute(
        profileID: UUID,
        startingAt requestedArcid: String? = nil,
        startAtLastPage: Bool = false
    ) -> ReaderRoute? {
        guard let arcid = requestedArcid ?? archives.first,
              archives.contains(arcid) else { return nil }
        return ReaderRoute(
            profileID: profileID,
            arcid: arcid,
            tank: self,
            startAtLastPage: startAtLastPage
        )
    }
}

struct ReaderRoute: Hashable, Codable {
    var profileID: UUID
    var arcid: String
    var tank: TankoubonReaderContext?
    var startAtLastPage: Bool

    init(
        profileID: UUID,
        arcid: String,
        tank: TankoubonReaderContext? = nil,
        startAtLastPage: Bool = false
    ) {
        self.profileID = profileID
        self.arcid = arcid
        self.tank = tank
        self.startAtLastPage = startAtLastPage
    }

    private enum CodingKeys: String, CodingKey {
        case profileID
        case arcid
        case tank
        case startAtLastPage
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        arcid = try container.decode(String.self, forKey: .arcid)
        tank = try container.decodeIfPresent(TankoubonReaderContext.self, forKey: .tank)
        startAtLastPage = try container.decodeIfPresent(Bool.self, forKey: .startAtLastPage) ?? false
    }
}
