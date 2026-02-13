import Foundation

public struct ArchiveMetadata: Decodable, Sendable, Equatable {
    public var arcid: String
    public var title: String?
    public var tags: String?
    public var summary: String?
    public var pagecount: Int?
    public var filename: String?
    public var category: String?
    public var isnew: Bool?
    public var progress: Int?
    public var lastreadtime: Int?

    public init(
        arcid: String,
        title: String? = nil,
        tags: String? = nil,
        summary: String? = nil,
        pagecount: Int? = nil,
        filename: String? = nil,
        category: String? = nil,
        isnew: Bool? = nil,
        progress: Int? = nil,
        lastreadtime: Int? = nil
    ) {
        self.arcid = arcid
        self.title = title
        self.tags = tags
        self.summary = summary
        self.pagecount = pagecount
        self.filename = filename
        self.category = category
        self.isnew = isnew
        self.progress = progress
        self.lastreadtime = lastreadtime
    }
}

