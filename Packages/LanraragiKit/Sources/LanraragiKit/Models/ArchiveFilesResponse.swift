import Foundation

public struct ArchiveFilesResponse: Decodable, Sendable, Equatable {
    public var job: Int?
    public var pages: [String]

    public init(job: Int? = nil, pages: [String]) {
        self.job = job
        self.pages = pages
    }
}

