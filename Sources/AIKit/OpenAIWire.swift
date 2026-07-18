import Foundation

/// Erreurs du client IA.
public enum AIError: Error, Equatable {
    case emptyResponse
    case http(status: Int, body: String)
    case decoding(String)
}

extension AIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyResponse:
            "Réponse vide de l'IA."
        case .http(let status, let body):
            "Erreur HTTP \(status) de l'endpoint IA" + (body.isEmpty ? "" : " — \(body.prefix(600))")
        case .decoding(let message):
            "Réponse IA illisible : \(message)"
        }
    }
}

// DTOs « fil » OpenAI-compatibles (Chat Completions).
struct WireMessage: Codable, Equatable {
    let role: String
    let content: String
}

struct ChatCompletionRequestBody: Encodable {
    let model: String
    let messages: [WireMessage]
    let stream: Bool
    let temperature: Double?
}

struct ChatCompletionResponseBody: Decodable {
    struct Choice: Decodable { let message: WireMessage }
    let choices: [Choice]
}
