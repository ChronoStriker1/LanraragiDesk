import Foundation
import LanraragiKit

enum ErrorPresenter {
    static func isCancellationLike(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let e = error as? URLError, e.code == .cancelled { return true }
        if let e = error as? LANraragiError {
            switch e {
            case .transport(let underlying):
                return isCancellationLike(underlying)
            default:
                return false
            }
        }
        return false
    }

    static func short(_ error: Error) -> String {
        if let e = error as? LANraragiError {
            switch e {
            case .unauthorized:
                return "Unauthorized"
            case .invalidBaseURL:
                return "Bad URL"
            case .invalidResponse:
                return "Bad response"
            case .httpStatus(let code, _):
                if code == 404 { return "Missing" }
                return "HTTP \(code)"
            case .decoding:
                return "Decode failed"
            case .transport(let underlying):
                if let u = underlying as? URLError {
                    switch u.code {
                    case .timedOut: return "Timed out"
                    case .cannotConnectToHost: return "Can't connect"
                    case .networkConnectionLost: return "Conn lost"
                    case .notConnectedToInternet: return "Offline"
                    case .cancelled: return "Cancelled"
                    default: break
                    }
                }
                if underlying is CancellationError { return "Cancelled" }
                return "Network error"
            }
        }

        if let u = error as? URLError {
            if u.code == .cancelled { return "Cancelled" }
            if u.code == .timedOut { return "Timed out" }
        }

        if error is CancellationError { return "Cancelled" }
        return "Error"
    }
}

