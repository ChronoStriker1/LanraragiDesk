import Foundation

public struct MinionJob: Decodable, Sendable, Equatable {
    public var job: Int

    public init(job: Int) {
        self.job = job
    }
}

public struct MinionStatus: Decodable, Sendable, Equatable {
    public struct State: Decodable, Sendable, Equatable {
        public var state: String?
    }

    public var state: String?

    // Some LRR / LANraragi variants nest state; tolerate either.
    public var data: State?
}
