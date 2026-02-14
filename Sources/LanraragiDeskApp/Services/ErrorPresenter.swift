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
                if case .httpStatus(_, let body) = e, let body, !body.isEmpty {
                    if let msg = extractMessage(fromHTTPBody: body) {
                        return "HTTP \(code): \(msg)"
                    }
                }
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

    private static func extractMessage(fromHTTPBody body: Data) -> String? {
        // LANraragi often returns JSON error bodies; if not, fall back to a short UTF-8 snippet.
        if
            let obj = try? JSONSerialization.jsonObject(with: body),
            let dict = obj as? [String: Any]
        {
            let candidates = ["error", "message", "reason", "detail"]
            for k in candidates {
                if let s = dict[k] as? String, !s.isEmpty {
                    return truncate(s)
                }
            }
        }

        let s = String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return truncate(s)
    }

    private static func truncate(_ s: String, max: Int = 120) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]) + "…"
    }
}
