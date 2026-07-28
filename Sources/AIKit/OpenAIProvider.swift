import Foundation

/// Construit les requêtes HTTP vers un endpoint OpenAI-compatible. Isolé pour être testable
/// sans réseau (le token vient du Keychain en amont — jamais stocké ici durablement).
public struct OpenAIRequestBuilder: Sendable {
    public let endpoint: AIEndpoint
    public let apiToken: String
    public var temperature: Double?

    public init(endpoint: AIEndpoint, apiToken: String, temperature: Double? = nil) {
        self.endpoint = endpoint
        self.apiToken = apiToken
        self.temperature = temperature
    }

    public func buildChatRequest(messages: [ChatMessage], stream: Bool) throws -> URLRequest {
        let url = endpoint.baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        let body = ChatCompletionRequestBody(
            model: endpoint.model,
            messages: messages.map { WireMessage(role: $0.role.rawValue, content: $0.content) },
            stream: stream,
            temperature: temperature
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
}

/// Parse la réponse non-streamée en `ChatMessage`.
public enum OpenAIResponseParser {
    public static func parseChatMessage(from data: Data) throws -> ChatMessage {
        let body: ChatCompletionResponseBody
        do {
            body = try JSONDecoder().decode(ChatCompletionResponseBody.self, from: data)
        } catch {
            throw AIError.decoding("\(error)")
        }
        guard let first = body.choices.first else { throw AIError.emptyResponse() }
        guard let content = first.message.content, !content.isEmpty else {
            throw AIError.emptyResponse(finishReason: first.finishReason)
        }
        return ChatMessage(role: .assistant, content: content)
    }
}

/// Provider OpenAI-compatible s'appuyant sur `URLSession`. Le réseau réel n'est pas testé
/// en unitaire ; la construction/parse le sont (voir `OpenAIRequestBuilder`/`OpenAIResponseParser`).
public struct OpenAICompatibleProvider: AIProvider {
    let builder: OpenAIRequestBuilder
    let session: URLSession

    public init(endpoint: AIEndpoint, apiToken: String, session: URLSession = .shared) {
        self.builder = OpenAIRequestBuilder(endpoint: endpoint, apiToken: apiToken)
        self.session = session
    }

    public func complete(messages: [ChatMessage]) async throws -> ChatMessage {
        let request = try builder.buildChatRequest(messages: messages, stream: false)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(status: http.statusCode, body: body)
        }
        return try OpenAIResponseParser.parseChatMessage(from: data)
    }
}
