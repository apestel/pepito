import Foundation
import AIKit

/// Résultat d'un test de connexion à l'endpoint IA (exposé à l'UI sans fuiter les types AIKit).
public enum ConnectionTestResult: Sendable, Equatable {
    case success(model: String)
    case failure(String)
}

extension AppCore {
    /// Construit un provider OpenAI-compatible depuis les réglages + token (façade pour l'app).
    public static func makeProvider(settings: Settings, token: String) -> (any AIProvider)? {
        guard let url = URL(string: settings.aiBaseURL) else { return nil }
        return OpenAICompatibleProvider(
            endpoint: AIEndpoint(baseURL: url, model: settings.aiModel),
            apiToken: token
        )
    }

    /// Teste la connexion en envoyant un court message. Utilisé par « Tester la connexion » (Phase 6).
    public static func testConnection(settings: Settings, token: String) async -> ConnectionTestResult {
        guard let provider = makeProvider(settings: settings, token: token) else {
            return .failure("URL d'endpoint invalide")
        }
        do {
            // Message system + user, comme le vrai pipeline agentic, pour détecter les endpoints
            // qui acceptent un appel trivial mais refusent une requête réaliste.
            _ = try await provider.complete(messages: [
                ChatMessage(role: .system, content: "Tu es un assistant de test."),
                ChatMessage(role: .user, content: "Réponds simplement: OK."),
            ])
            return .success(model: settings.aiModel)
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
