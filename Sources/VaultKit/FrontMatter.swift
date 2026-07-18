/// Sérialisation/parsing minimaliste de front-matter YAML (paires clé: valeur string).
/// Suffisant pour les métadonnées de documents ; volontairement simple et déterministe.
public enum FrontMatter {
    public static func serialize(_ dict: [String: String]) -> String {
        guard !dict.isEmpty else { return "" }
        return dict.keys.sorted()
            .map { key in "\(key): \(escape(dict[key]!))" }
            .joined(separator: "\n")
    }

    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") {
                val = String(val.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
            }
            if !key.isEmpty { result[key] = val }
        }
        return result
    }

    static func escape(_ value: String) -> String {
        let needsQuote = value.contains(":") || value.contains("#")
            || value.contains("\n") || value.hasPrefix(" ") || value.hasSuffix(" ")
            || value.isEmpty
        guard needsQuote else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
