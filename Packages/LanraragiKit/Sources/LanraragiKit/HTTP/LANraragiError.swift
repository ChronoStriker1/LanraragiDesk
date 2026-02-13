import Foundation

public enum LANraragiError: Error, Sendable {
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int, body: Data?)
    case unauthorized
    case decoding(Error)
    case transport(Error)
}
