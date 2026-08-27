import Foundation

struct BatchQueryCondition: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: ConditionType
    var namespace: String = ""
    var value: String = ""
    var categoryID: String = ""

    var validationMessage: String? {
        let normalizedNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch type {
        case .tagPresent, .tagAbsent:
            if normalizedNamespace.isEmpty { return "Enter a namespace." }
            if normalizedNamespace.contains(",") { return "Namespaces cannot contain commas." }
        case .tagEquals, .tagNotEquals:
            if normalizedNamespace.isEmpty { return "Enter a namespace." }
            if normalizedNamespace.contains(",") { return "Namespaces cannot contain commas." }
            if normalizedValue.isEmpty { return "Enter an exact tag value." }
            if normalizedValue.contains(",") { return "Exact tag values cannot contain commas." }
        case .serverCategory:
            if categoryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Select a category."
            }
        case .newOnly, .untaggedOnly:
            break
        }

        return nil
    }

    var isValid: Bool { validationMessage == nil }

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
            case .tagPresent: return "Namespace has any tag"
            case .tagAbsent: return "Namespace has no tags"
            case .tagEquals: return "Exact tag is present"
            case .tagNotEquals: return "Exact tag is absent"
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
            guard condition.isValid else { continue }

            let namespace = condition.namespace.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)

            switch condition.type {
            case .tagPresent:
                filterParts.append("\(namespace):")
            case .tagAbsent:
                filterParts.append("-\(namespace):")
            case .tagEquals:
                filterParts.append("\(namespace):\(value)$")
            case .tagNotEquals:
                filterParts.append("-\(namespace):\(value)$")
            case .serverCategory:
                categoryID = condition.categoryID.trimmingCharacters(in: .whitespacesAndNewlines)
            case .newOnly:
                newOnly = true
            case .untaggedOnly:
                untaggedOnly = true
            }
        }

        return CompiledQuery(
            // LANraragi's search parser uses commas, not whitespace, to delimit predicates.
            filter: filterParts.joined(separator: ", "),
            categoryID: categoryID,
            newOnly: newOnly,
            untaggedOnly: untaggedOnly
        )
    }
}
