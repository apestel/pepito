import Foundation

/// Client IA générative OpenAI-compatible + boucle agentic. Implémentation Phases 4-5 (PLAN.md).
public enum AIKit {
    public static let moduleName = "AIKit"
}

/// Configuration d'un endpoint OpenAI-compatible. Le token vit en Keychain, jamais ici en clair.
public struct AIEndpoint: Sendable, Equatable {
    public var baseURL: URL
    public var model: String

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }
}

/// Rôle d'un message de conversation.
public enum ChatRole: String, Sendable, Codable {
    case system, user, assistant, tool
}

public struct ChatMessage: Sendable, Equatable, Codable {
    public var role: ChatRole
    public var content: String

    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// Contrat de provider IA (OpenAI-compatible ou Foundation Models on-device), mockable.
public protocol AIProvider: Sendable {
    func complete(messages: [ChatMessage]) async throws -> ChatMessage
}
