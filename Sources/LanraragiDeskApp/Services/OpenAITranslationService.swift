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

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
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

        let payloadJSON = try TitleTranslationFormat.payloadJSON(items: items)

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                [
                    "role": "system",
                    "content": "You detect title language and translate non-English titles to concise natural English. Return strict JSON only. \(TitleTranslationFormat.languageInstruction)"
                ],
                [
                    "role": "user",
                    "content": "For each item, return arcid, detected_language, english_title, should_translate. Keep english_title same as input when should_translate=false. Input items: \(payloadJSON)"
                ]
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "title_translation_batch",
                    "strict": true,
                    "schema": try TitleTranslationFormat.schemaObject()
                ]
            ]
        ]

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

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

        return try TitleTranslationFormat.decodeEnvelope(content)
    }

    func availableModelIDs(apiKey: String) async throws -> [String] {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if let msg = String(data: data, encoding: .utf8), !msg.isEmpty {
                throw NSError(domain: "OpenAITranslationService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            throw NSError(domain: "OpenAITranslationService", code: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map(\.id)
    }
}
