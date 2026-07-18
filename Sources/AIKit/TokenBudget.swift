import Foundation

/// Estimation grossière du nombre de tokens (~4 caractères/token) pour piloter le chunking.
public enum TokenEstimator {
    public static func estimateTokens(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }
}

/// Découpe un long transcript en morceaux sous un budget de tokens, sur les frontières de lignes
/// quand c'est possible (préparation d'un résumé map-reduce — Phase 4/5).
public enum TranscriptChunker {
    public static func chunk(_ text: String, maxTokensPerChunk: Int) -> [String] {
        let budget = max(1, maxTokensPerChunk * 4) // en caractères
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { chunks.append(current); current = "" }
        }

        for line in lines {
            if line.count > budget {
                flush()
                chunks.append(contentsOf: hardSplit(line, budget: budget))
                continue
            }
            if current.isEmpty {
                current = line
            } else if current.count + 1 + line.count <= budget {
                current += "\n" + line
            } else {
                flush()
                current = line
            }
        }
        flush()
        return chunks
    }

    private static func hardSplit(_ text: String, budget: Int) -> [String] {
        var pieces: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
            pieces.append(String(text[start..<end]))
            start = end
        }
        return pieces
    }
}
