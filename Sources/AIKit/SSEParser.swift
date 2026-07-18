import Foundation

/// Parsing des flux Server-Sent Events du streaming OpenAI (`data: {json}` / `data: [DONE]`).
public enum SSEParser {
    /// Extrait le delta de contenu d'un évènement JSON de streaming.
    public static func extractDelta(fromEventJSON json: Data) -> String? {
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta
            }
            let choices: [Choice]
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: json) else { return nil }
        return chunk.choices.first?.delta.content
    }

    /// Recompose le texte complet à partir d'un flux SSE (utile pour tests et accumulation).
    public static func accumulate(sse text: String) -> String {
        var output = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            if let delta = extractDelta(fromEventJSON: Data(payload.utf8)) {
                output += delta
            }
        }
        return output
    }
}
