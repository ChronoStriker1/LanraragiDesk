import Foundation

/// Shared helpers for LANraragi's comma-separated `namespace:value` tag strings.
enum TagParsing {
    private static let dateOnlyParsers: [DateFormatter] = {
        func make(_ format: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = format
            return f
        }
        return [
            make("yyyy-MM-dd"),
            make("yyyy/MM/dd"),
        ]
    }()

    /// Splits a raw tag string into trimmed, non-empty tokens.
    static func tokens(_ tags: String?) -> [String] {
        (tags ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Splits `namespace:value`; returns an empty namespace when no colon is present.
    static func splitNamespace(_ tok: String) -> (namespace: String, value: String) {
        guard let idx = tok.firstIndex(of: ":") else { return ("", tok) }
        let ns = String(tok[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let v = String(tok[tok.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (ns, v)
    }

    static func isDateNamespace(_ ns: String) -> Bool {
        let n = ns.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return n == "date_added" || n == "dateadded" || n == "date"
    }

    /// Parses a date tag value: unix seconds or milliseconds, or `yyyy-MM-dd`/`yyyy/MM/dd`.
    static func parseDateValue(_ v: String) -> Date? {
        let value = v.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "\"'"))

        if let rawNum = Int64(value) {
            let seconds: TimeInterval
            if rawNum > 1_000_000_000_000 {
                seconds = TimeInterval(rawNum) / 1000.0
            } else {
                seconds = TimeInterval(rawNum)
            }
            return Date(timeIntervalSince1970: seconds)
        }

        for f in dateOnlyParsers {
            if let d = f.date(from: value) {
                return d
            }
        }

        return nil
    }

    /// Finds the first parseable `date_added`/`dateadded`/`date` tag.
    static func parseDateAddedTag(_ tags: String) -> Date? {
        for tok in tokens(tags) {
            let (ns, value) = splitNamespace(tok)
            guard isDateNamespace(ns) else { continue }
            if let d = parseDateValue(value) {
                return d
            }
        }
        return nil
    }

    /// Values for one namespace, order-stable and case-insensitively de-duped.
    static func values(in tags: String, namespace: String) -> [String] {
        let ns = namespace.lowercased()
        var seen: Set<String> = []
        var out: [String] = []

        for tok in tokens(tags) {
            guard let idx = tok.firstIndex(of: ":") else { continue }
            let lhs = tok[..<idx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard lhs == ns else { continue }
            let rhs = tok[tok.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !rhs.isEmpty, seen.insert(rhs.lowercased()).inserted {
                out.append(rhs)
            }
        }

        return out
    }
}
