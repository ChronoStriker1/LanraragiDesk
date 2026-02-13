import Foundation

public struct ArchiveIdOnly: Decodable, Sendable, Equatable {
    public var arcid: String

    public init(arcid: String) {
        self.arcid = arcid
    }
}

public struct ArchiveSearch: Decodable, Sendable, Equatable {
    public var data: [ArchiveIdOnly]
    public var recordsFiltered: Int
    public var recordsTotal: Int

    public init(data: [ArchiveIdOnly], recordsFiltered: Int, recordsTotal: Int) {
        self.data = data
        self.recordsFiltered = recordsFiltered
        self.recordsTotal = recordsTotal
    }
}
