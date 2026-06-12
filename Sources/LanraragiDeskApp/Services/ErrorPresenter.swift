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
                    return truncate(decodeHTMLEntities(s))
                }
            }
        }

        let s = String(decoding: body, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return truncate(decodeHTMLEntities(s))
    }

    private static func truncate(_ s: String, max: Int = 120) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]) + "…"
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        var output = input
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")

        output = replaceNumericHTMLEntities(in: output, pattern: #"&#(\d+);"#, radix: 10)
        output = replaceNumericHTMLEntities(in: output, pattern: #"&#x([0-9a-fA-F]+);"#, radix: 16)
        return output
    }

    private static func replaceNumericHTMLEntities(in input: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        var output = input
        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).reversed()
        for match in matches {
            guard
                match.numberOfRanges == 2,
                let entityRange = Range(match.range(at: 0), in: output),
                let valueRange = Range(match.range(at: 1), in: output),
                let scalarValue = UInt32(output[valueRange], radix: radix),
                let scalar = UnicodeScalar(scalarValue)
            else { continue }
            output.replaceSubrange(entityRange, with: String(Character(scalar)))
        }
        return output
    }
}
