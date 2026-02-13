import Foundation

public enum ThumbnailResponse: Sendable, Equatable {
    case bytes(Data)
    case job(MinionJob)
}
