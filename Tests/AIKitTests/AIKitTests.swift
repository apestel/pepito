import Testing
import Foundation
@testable import AIKit

@Test func moduleIdentity() {
    #expect(AIKit.moduleName == "AIKit")
}

@Test func endpointHoldsConfig() {
    let endpoint = AIEndpoint(baseURL: URL(string: "https://api.openai.com/v1")!, model: "gpt-4o")
    #expect(endpoint.model == "gpt-4o")
}

@Test func chatMessageRoundtrip() throws {
    let msg = ChatMessage(role: .user, content: "salut")
    let data = try JSONEncoder().encode(msg)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
    #expect(decoded == msg)
}

// MARK: - Request building

@Test func buildsChatRequestWithAuthAndPath() throws {
    let endpoint = AIEndpoint(baseURL: URL(string: "https://api.openai.com/v1")!, model: "gpt-4o")
    let builder = OpenAIRequestBuilder(endpoint: endpoint, apiToken: "sk-test")
    let req = try builder.buildChatRequest(
        messages: [ChatMessage(role: .user, content: "bonjour")],
        stream: false
    )
    #expect(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(req.httpBody)
    let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
    #expect(json?["model"] as? String == "gpt-4o")
    #expect(json?["stream"] as? Bool == false)
}

// MARK: - Response parsing

@Test func parsesChatResponse() throws {
    let json = """
    {"choices":[{"message":{"role":"assistant","content":"Réponse."}}]}
    """
    let msg = try OpenAIResponseParser.parseChatMessage(from: Data(json.utf8))
    #expect(msg.role == .assistant)
    #expect(msg.content == "Réponse.")
}

@Test func emptyChoicesThrows() {
    let json = #"{"choices":[]}"#
    #expect(throws: AIError.emptyResponse) {
        try OpenAIResponseParser.parseChatMessage(from: Data(json.utf8))
    }
}

// MARK: - SSE

@Test func accumulatesSSEStream() {
    let sse = """
    data: {"choices":[{"delta":{"content":"Bon"}}]}

    data: {"choices":[{"delta":{"content":"jour"}}]}

    data: [DONE]
    """
    #expect(SSEParser.accumulate(sse: sse) == "Bonjour")
}

@Test func ignoresNonDataLines() {
    let sse = """
    : ping
    data: {"choices":[{"delta":{"content":"X"}}]}
    """
    #expect(SSEParser.accumulate(sse: sse) == "X")
}

// MARK: - Token budget / chunking

@Test func tokenEstimateApprox() {
    #expect(TokenEstimator.estimateTokens("") == 1)
    #expect(TokenEstimator.estimateTokens(String(repeating: "a", count: 40)) == 10)
}

@Test func chunkingRespectsBudget() {
    let text = (1...20).map { "Ligne numéro \($0) du transcript." }.joined(separator: "\n")
    let chunks = TranscriptChunker.chunk(text, maxTokensPerChunk: 10) // ~40 chars/chunk
    #expect(chunks.count > 1)
    for chunk in chunks {
        #expect(chunk.count <= 40)
    }
    // Aucune donnée perdue (hors séparateurs) : la concaténation contient toutes les lignes.
    let joined = chunks.joined(separator: "\n")
    #expect(joined.contains("Ligne numéro 1 "))
    #expect(joined.contains("Ligne numéro 20 "))
}

@Test func hardSplitsOverlongLine() {
    let long = String(repeating: "z", count: 100)
    let chunks = TranscriptChunker.chunk(long, maxTokensPerChunk: 5) // budget 20 chars
    #expect(chunks.count == 5)
    #expect(chunks.allSatisfy { $0.count <= 20 })
}
