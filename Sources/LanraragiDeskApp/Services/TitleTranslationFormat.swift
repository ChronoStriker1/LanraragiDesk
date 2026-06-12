import Foundation

/// Shared prompt fragments, JSON schema, and envelope decoding for the title
/// translation providers (OpenAI API and Codex CLI). Both must stay in sync on
/// the wire format, so it lives in one place.
enum TitleTranslationFormat {
    static let languageInstruction =
        "Language enum must be one of: english, japanese, korean, chinese, spanish, romanji, other. Treat romaji/romanji text as romanji."

    /// JSON schema for the `{ "items": [...] }` translation envelope.
    static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "items": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "arcid": { "type": "string" },
              "detected_language": {
                "type": "string",
                "enum": ["english", "japanese", "korean", "chinese", "spanish", "romanji", "other"]
              },
              "english_title": { "type": "string" },
              "should_translate": { "type": "boolean" }
            },
            "required": ["arcid", "detected_language", "english_title", "should_translate"],
            "additionalProperties": false
          }
        }
      },
      "required": ["items"],
      "additionalProperties": false
    }
    """

    static func schemaObject() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) as? [String: Any] else {
            throw NSError(domain: "TitleTranslationFormat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Schema JSON is not an object."])
        }
        return object
    }

    /// Encodes batch items as the JSON array embedded in the prompt.
    static func payloadJSON(items: [OpenAITranslationService.BatchItem]) throws -> String {
        let promptItems = items.map { ["arcid": $0.arcid, "title": $0.title] }
        let data = try JSONSerialization.data(withJSONObject: promptItems, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Decodes a provider's `{ "items": [...] }` response payload.
    static func decodeEnvelope(_ content: String) throws -> [OpenAITranslationService.BatchResult] {
        struct OutputEnvelope: Decodable {
            let items: [OpenAITranslationService.BatchResult]
        }
        return try JSONDecoder().decode(OutputEnvelope.self, from: Data(content.utf8)).items
    }
}
