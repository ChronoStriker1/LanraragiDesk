import Foundation

enum ProfileEditorMode: Identifiable {
    case add
    case edit(Profile)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let p):
            return p.id.uuidString
        }
    }
}
