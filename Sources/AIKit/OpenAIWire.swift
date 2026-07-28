import Foundation

/// Erreurs du client IA.
public enum AIError: Error, Equatable {
    case emptyResponse(finishReason: String? = nil)
    case http(status: Int, body: String)
    case decoding(String)
}

extension AIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyResponse(let finishReason):
            "Réponse vide de l'IA" + (finishReason.map { " (finish_reason: \($0))" } ?? "") + "."
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

/// `content` est optionnel côté réponse : une gateway peut renvoyer `null` (modèle qui part en
/// tool-call, réponse filtrée, budget de sortie mangé par le raisonnement). C'est une réponse vide,
/// pas un JSON illisible — le décoder strictement transformait ce cas en `DecodingError` opaque.
struct ChatCompletionResponseBody: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }
    let choices: [Choice]
}
