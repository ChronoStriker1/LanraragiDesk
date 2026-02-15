import Foundation

@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var events: [ActivityEvent] = []

    private let maxEvents = 2000

    init() {
        load()
    }

    func add(_ event: ActivityEvent) {
        events.insert(event, at: 0)
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
}

