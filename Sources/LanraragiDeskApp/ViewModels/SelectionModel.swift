import Foundation

@MainActor
final class SelectionModel: ObservableObject {
    @Published private(set) var arcids: Set<String> = []

    var count: Int { arcids.count }

    func contains(_ arcid: String) -> Bool {
        arcids.contains(arcid)
    }

    func toggle(_ arcid: String) {
        if arcids.contains(arcid) {
            arcids.remove(arcid)
        } else {
            arcids.insert(arcid)
        }
    }

    func remove(_ arcid: String) {
        arcids.remove(arcid)
    }

    func clear() {
        arcids.removeAll()
    }
}
