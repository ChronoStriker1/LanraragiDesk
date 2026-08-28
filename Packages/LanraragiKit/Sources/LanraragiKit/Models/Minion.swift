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

    public struct Result: Decodable, Sendable, Equatable {
        public struct Metadata: Decodable, Sendable, Equatable {
            public var title: String?
            public var newTags: String?
            public var tags: String?
            public var summary: String?

            private enum CodingKeys: String, CodingKey {
                case title
                case newTags = "new_tags"
                case tags
                case summary
            }
        }

        public var type: String?
        public var success: Int?
        public var error: String?
        public var data: Metadata?
        public private(set) var dataWasMalformed: Bool

        private enum CodingKeys: String, CodingKey {
            case type
            case success
            case error
            case data
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decode(String.self, forKey: .type)
            success = try? container.decode(Int.self, forKey: .success)
            error = try? container.decode(String.self, forKey: .error)
            do {
                data = try container.decodeIfPresent(Metadata.self, forKey: .data)
                dataWasMalformed = false
            } catch {
                data = nil
                dataWasMalformed = container.contains(.data)
            }
        }
    }

    public var state: String?

    // Some LRR / LANraragi variants nest state; tolerate either.
    public var data: State?

    /// Present on the authenticated `/api/minion/:job/detail` response.
    public var result: Result?
    public var error: String?

    private enum CodingKeys: String, CodingKey {
        case state
        case data
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try? container.decode(String.self, forKey: .state)
        data = try? container.decode(State.self, forKey: .data)
        result = try? container.decode(Result.self, forKey: .result)
        error = try? container.decode(String.self, forKey: .error)
    }
}
