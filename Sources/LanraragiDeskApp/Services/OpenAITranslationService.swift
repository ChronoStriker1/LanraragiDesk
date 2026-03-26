import Foundation

struct OpenAITranslationService {
    struct BatchItem: Sendable {
        let arcid: String
        let title: String
    }

    struct BatchResult: Sendable, Decodable {
        let arcid: String
        let detectedLanguage: String
        let englishTitle: String
        let shouldTranslate: Bool

        enum CodingKeys: String, CodingKey {
            case arcid
            case detectedLanguage = "detected_language"
            case englishTitle = "english_title"
            case shouldTranslate = "should_translate"
        }
    }

    enum ServiceError: Error {
        case invalidResponse
        case missingContent
    }

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct ResponseFormat: Encodable {
            struct JSONSchema: Encodable {
                let name: String
                let strict: Bool
                let schema: Schema

                struct Schema: Encodable {
                    let type: String
                    let properties: [String: Property]
                    let required: [String]
                    let additionalProperties: Bool

                    struct Property: Encodable {
                        let type: String
                        let items: Items?

                        struct Items: Encodable {
                            let type: String
                            let properties: [String: ItemProperty]
                            let required: [String]
                            let additionalProperties: Bool

                            struct ItemProperty: Encodable {
                                let type: String
                                let `enum`: [String]?

                                init(type: String, enum values: [String]? = nil) {
                                    self.type = type
                                    self.enum = values
                                }
                            }
                        }
                    }
                }
            }

            let type: String
            let jsonSchema: JSONSchema

            enum CodingKeys: String, CodingKey {
                case type
                case jsonSchema = "json_schema"
            }
        }

        let model: String
        let temperature: Double
        let messages: [Message]
        let responseFormat: ResponseFormat

        enum CodingKeys: String, CodingKey {
            case model
            case temperature
            case messages
            case responseFormat = "response_format"
        }
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private struct OutputEnvelope: Decodable {
        let items: [BatchResult]
    }

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func translateBatch(
        apiKey: String,
        model: String,
        items: [BatchItem]
    ) async throws -> [BatchResult] {
        guard !items.isEmpty else { return [] }

        let promptItems = items.map { ["arcid": $0.arcid, "title": $0.title] }
        let payloadJSON = try String(data: JSONSerialization.data(withJSONObject: promptItems, options: [.sortedKeys]), encoding: .utf8) ?? "[]"

        let body = RequestBody(
            model: model,
            temperature: 0,
            messages: [
                .init(
                    role: "system",
                    content: "You detect title language and translate non-English titles to concise natural English. Return strict JSON only. Language enum must be one of: english, japanese, korean, chinese, spanish, romanji, other. Treat romaji/romanji text as romanji."
                ),
                .init(
                    role: "user",
                    content: "For each item, return arcid, detected_language, english_title, should_translate. Keep english_title same as input when should_translate=false. Input items: \(payloadJSON)"
                )
            ],
            responseFormat: .init(
                type: "json_schema",
                jsonSchema: .init(
                    name: "title_translation_batch",
                    strict: true,
                    schema: .init(
                        type: "object",
                        properties: [
                            "items": .init(
                                type: "array",
                                items: .init(
                                    type: "object",
                                    properties: [
                                        "arcid": .init(type: "string"),
                                        "detected_language": .init(type: "string", enum: ["english", "japanese", "korean", "chinese", "spanish", "romanji", "other"]),
                                        "english_title": .init(type: "string"),
                                        "should_translate": .init(type: "boolean")
                                    ],
                                    required: ["arcid", "detected_language", "english_title", "should_translate"],
                                    additionalProperties: false
                                )
                            )
                        ],
                        required: ["items"],
                        additionalProperties: false
                    )
                )
            )
        )

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if let msg = String(data: data, encoding: .utf8), !msg.isEmpty {
                throw NSError(domain: "OpenAITranslationService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            throw NSError(domain: "OpenAITranslationService", code: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw ServiceError.missingContent
        }

        let envelope = try JSONDecoder().decode(OutputEnvelope.self, from: Data(content.utf8))
        return envelope.items
    }
}
