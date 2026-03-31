import Foundation

enum TitleTranslationProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case openAIAPI
    case codexCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIAPI:
            "OpenAI API"
        case .codexCLI:
            "Codex"
        }
    }
}

struct TitleTranslationConfig: Sendable, Codable {
    let provider: TitleTranslationProvider
    let model: String
    let openAIKey: String?
}

protocol TitleTranslationProviderClient: Sendable {
    func translateBatch(
        model: String,
        items: [OpenAITranslationService.BatchItem]
    ) async throws -> [OpenAITranslationService.BatchResult]
}

struct OpenAITranslationProviderClient: TitleTranslationProviderClient {
    let apiKey: String
    private let service: OpenAITranslationService

    init(apiKey: String, service: OpenAITranslationService = OpenAITranslationService()) {
        self.apiKey = apiKey
        self.service = service
    }

    func translateBatch(
        model: String,
        items: [OpenAITranslationService.BatchItem]
    ) async throws -> [OpenAITranslationService.BatchResult] {
        try await service.translateBatch(apiKey: apiKey, model: model, items: items)
    }
}
