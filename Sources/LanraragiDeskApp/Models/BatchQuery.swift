import Foundation

struct BatchQueryCondition: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: ConditionType
    var namespace: String = ""
    var value: String = ""
    var categoryID: String = ""
    var categoryName: String = ""

    enum ConditionType: String, Codable, CaseIterable {
        case tagPresent
        case tagAbsent
        case tagEquals
        case tagNotEquals
        case serverCategory
        case newOnly
        case untaggedOnly

        var label: String {
            switch self {
            case .tagPresent: return "Tag is present"
            case .tagAbsent: return "Tag is absent"
            case .tagEquals: return "Tag equals"
            case .tagNotEquals: return "Tag not equals"
            case .serverCategory: return "LNR Category"
            case .newOnly: return "New only"
            case .untaggedOnly: return "Untagged only"
            }
        }

        var needsNamespace: Bool {
            switch self {
            case .tagPresent, .tagAbsent, .tagEquals, .tagNotEquals: return true
            default: return false
            }
        }

        var needsValue: Bool {
            switch self {
            case .tagEquals, .tagNotEquals: return true
            default: return false
            }
        }

        var needsCategory: Bool { self == .serverCategory }
    }
}

struct SavedBatchQuery: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var profileID: UUID
    var conditions: [BatchQueryCondition]
    var createdAt: Date = Date()
}

enum BatchQueryCompiler {
    struct CompiledQuery {
        var filter: String
        var categoryID: String
        var newOnly: Bool
        var untaggedOnly: Bool
        var isEmpty: Bool { filter.isEmpty && categoryID.isEmpty && !newOnly && !untaggedOnly }
    }

    static func compile(_ conditions: [BatchQueryCondition]) -> CompiledQuery {
        var filterParts: [String] = []
        var categoryID = ""
        var newOnly = false
        var untaggedOnly = false

        for condition in conditions {
            switch condition.type {
            case .tagPresent:
                if !condition.namespace.isEmpty {
                    filterParts.append("\(condition.namespace):")
                }
            case .tagAbsent:
                if !condition.namespace.isEmpty {
                    filterParts.append("-\(condition.namespace):")
                }
            case .tagEquals:
                if !condition.namespace.isEmpty {
                    filterParts.append("\(condition.namespace):\(condition.value)")
                }
            case .tagNotEquals:
                if !condition.namespace.isEmpty {
                    filterParts.append("-\(condition.namespace):\(condition.value)")
                }
            case .serverCategory:
                categoryID = condition.categoryID
            case .newOnly:
                newOnly = true
            case .untaggedOnly:
                untaggedOnly = true
            }
        }

        return CompiledQuery(
            filter: filterParts.joined(separator: " "),
            categoryID: categoryID,
            newOnly: newOnly,
            untaggedOnly: untaggedOnly
        )
    }
}
