import CoreFoundation
import Foundation

/// The metadata fields a LANraragi plugin can return for an archive.
public struct PluginMetadataPatch: Equatable, Sendable {
    public let title: String?
    public let tags: String?
    public let summary: String?

    public init(title: String?, tags: String?, summary: String?) {
        self.title = title
        self.tags = tags
        self.summary = summary
    }
}

/// Display-ready values for a LANraragi plugin option.
public struct PluginOptionPresentation: Equatable, Sendable {
    public let name: String
    public let valueText: String
    public let isBoolean: Bool
    public let booleanValue: Bool?

    public init(name: String, valueText: String, isBoolean: Bool, booleanValue: Bool?) {
        self.name = name
        self.valueText = valueText
        self.isBoolean = isBoolean
        self.booleanValue = booleanValue
    }
}

/// The validated terminal result of a queued LANraragi metadata plugin job.
public enum QueuedPluginMetadataResult: Equatable, Sendable {
    case patch(PluginMetadataPatch)
    case noChanges
    case failed(message: String?)
    case missing
    case malformed
    case nonMetadata(type: String?)

    public var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

/// Shared interpretation of plugin output and options used by single-archive and batch flows.
public enum PluginMetadataSupport {
    public static func parsePatch(from response: String) -> PluginMetadataPatch? {
        guard
            let data = response.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }

        guard let payload = extractPayload(from: object) else { return nil }

        let title = scalarString(payload["title"])
        let summary = scalarString(payload["summary"])
        let newTags = csvString(payload["new_tags"])
        let fullTags = csvString(payload["tags"])
        return makePatch(title: title, summary: summary, newTags: newTags, fullTags: fullTags)
    }

    /// Validates the result contract produced by LANraragi's `run_plugin`
    /// Minion task. A finished Minion job can still contain `success: 0`, so
    /// callers must inspect both the job state and its result.
    public static func queuedResult(from status: MinionStatus) -> QueuedPluginMetadataResult {
        let state = (status.state ?? status.data?.state)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if state == "failed" {
            return .failed(message: normalized(status.error))
        }

        guard let result = status.result else { return .missing }
        guard let success = result.success, success == 0 || success == 1 else { return .malformed }
        guard success == 1 else {
            return .failed(message: normalized(result.error))
        }

        guard let type = normalized(result.type) else { return .malformed }
        guard type.lowercased() == "metadata" else {
            return .nonMetadata(type: type)
        }

        guard !result.dataWasMalformed else { return .malformed }
        guard let data = result.data else { return .noChanges }
        let patch = makePatch(
            title: normalized(data.title),
            summary: normalized(data.summary),
            newTags: normalized(data.newTags),
            fullTags: normalized(data.tags)
        )
        return patch.map(QueuedPluginMetadataResult.patch) ?? .noChanges
    }

    /// Produces the comparison semantics historically used by the stronger batch flow.
    public static func signature(title: String, tags: String, summary: String) -> String {
        [
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedTagsForComparison(tags),
            summary.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "|||")
    }

    public static func optionPresentation(for parameter: PluginInfo.Parameter) -> PluginOptionPresentation {
        let rawName = parameter.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName.isEmpty ? "Option" : rawName

        let value = parameter.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = parameter.defaultValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let valueText = value.isEmpty ? fallback : value
        let lowercasedValue = valueText.lowercased()
        let type = parameter.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let isBoolean = type == "bool" || type == "boolean"
            || ["true", "false", "1", "0", "yes", "no"].contains(lowercasedValue)

        let booleanValue: Bool? = switch lowercasedValue {
        case "true", "1", "yes", "on": true
        case "false", "0", "no", "off": false
        default: nil
        }

        return PluginOptionPresentation(
            name: name,
            valueText: valueText,
            isBoolean: isBoolean,
            booleanValue: booleanValue
        )
    }

    private static func scalarString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func csvString(_ value: Any?) -> String? {
        if let scalar = scalarString(value) {
            return scalar
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { scalarString($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        return nil
    }

    private static func makePatch(
        title: String?,
        summary: String?,
        newTags: String?,
        fullTags: String?
    ) -> PluginMetadataPatch? {
        let tags = [newTags, fullTags]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTags = tags.isEmpty ? nil : tags
        guard title != nil || summary != nil || normalizedTags != nil else { return nil }
        return PluginMetadataPatch(title: title, tags: normalizedTags, summary: summary)
    }

    private static func extractPayload(from value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let nested = dictionary["data"], let payload = extractPayload(from: nested) {
                return payload
            }
            for key in ["result", "metadata", "plugin_data", "plugin_result"] {
                if let nested = dictionary[key], let payload = extractPayload(from: nested) {
                    return payload
                }
            }
            if ["title", "summary", "new_tags", "tags"].contains(where: { dictionary[$0] != nil }) {
                return dictionary
            }
        }

        if let array = value as? [Any] {
            for element in array {
                if let payload = extractPayload(from: element) {
                    return payload
                }
            }
        }

        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let nested = try? JSONSerialization.jsonObject(with: data) {
                return extractPayload(from: nested)
            }
        }

        return nil
    }

    private static func normalizedTagsForComparison(_ tags: String) -> String {
        tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: ",")
    }
}
