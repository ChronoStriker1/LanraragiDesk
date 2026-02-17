import Foundation

@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var events: [ActivityEvent] = []

    private let maxEvents = 2000

    init() {
        load()
    }

    func add(_ event: ActivityEvent) {
        events.insert(enriched(event), at: 0)
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
        save()
    }

    func clear() {
        events = []
        save()
    }

    private func load() {
        let url = AppPaths.activityLogURL()
        guard let data = try? Data(contentsOf: url) else {
            events = []
            return
        }
        if let decoded = try? JSONDecoder().decode([ActivityEvent].self, from: data) {
            events = decoded.sorted { $0.date > $1.date }
        } else {
            events = []
        }
    }

    private func save() {
        let url = AppPaths.activityLogURL()
        do {
            let data = try JSONEncoder().encode(events)
            try data.write(to: url, options: [.atomic])
        } catch {
            // Best-effort; the Activity view is not critical-path.
        }
    }

    private func enriched(_ event: ActivityEvent) -> ActivityEvent {
        var out = event
        if out.component == nil {
            out.component = inferComponent(from: out.title)
        }
        if out.metadata == nil {
            out.metadata = inferMetadata(title: out.title, detail: out.detail)
        }
        return out
    }

    private func inferComponent(from title: String) -> String? {
        let t = title.lowercased()
        if t.contains("plugin") { return "Plugin" }
        if t.contains("batch") { return "Batch" }
        if t.contains("duplicate") || t.contains("scan") { return "Duplicates" }
        if t.contains("stat") { return "Statistics" }
        if t.contains("reader") { return "Reader" }
        if t.contains("metadata") || t.contains("cover") { return "Metadata" }
        if t.contains("thumbnail") { return "Thumbnails" }
        if t.contains("tag suggestion") { return "Tag Suggestions" }
        if t.contains("archive") || t.contains("library") { return "Library" }
        return nil
    }

    private func inferMetadata(title: String, detail: String?) -> [String: String]? {
        let raw = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        var out: [String: String] = [:]

        let firstLine = raw.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? raw
        let bulletParts = firstLine.split(separator: "•").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if bulletParts.count >= 1, title.lowercased().contains("plugin") {
            out["plugin"] = bulletParts[0]
        }
        if bulletParts.count >= 2 {
            out["archive"] = bulletParts[1]
        }
        if bulletParts.count >= 3 {
            out["status"] = bulletParts[2]
        }

        if out["job"] == nil {
            if let range = raw.range(of: "job ", options: [.caseInsensitive]) {
                let suffix = raw[range.upperBound...]
                let job = suffix.prefix { $0.isNumber }
                if !job.isEmpty {
                    out["job"] = String(job)
                }
            }
        }

        if out.isEmpty {
            return nil
        }
        return out
    }
}
