import SwiftUI

/// Lightweight lexical coloring; source stays literal, selectable and never interpreted as HTML.
enum MissionCodeHighlight {
    static func render(_ source: String, language: String) -> AttributedString {
        let keywords: String
        let comment: String
        switch language {
        case "python":
            keywords = "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False|finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise|return|True|try|while|with|yield"
            comment = "#[^\\n]*"
        case "javascript":
            keywords = "async|await|break|case|catch|class|const|continue|default|delete|do|else|export|false|finally|for|from|function|if|import|in|instanceof|let|new|null|of|return|switch|throw|true|try|typeof|undefined|var|void|while|yield"
            comment = #"//[^\n]*|/\*[\s\S]*?\*/"#
        case "shell":
            keywords = "case|do|done|elif|else|esac|export|fi|for|function|if|in|local|then|until|while"
            comment = "#[^\\n]*"
        default: return AttributedString(source)
        }
        // ponytail: lexical coloring only; use a parser if full language grammar becomes necessary.
        let strings = #"\"\"\"[\s\S]*?\"\"\"|'''[\s\S]*?'''|\"(?:\\[\s\S]|[^\"\\])*\"|'(?:\\[\s\S]|[^'\\])*'|`(?:\\[\s\S]|[^`\\])*`"#
        let pattern = "(" + comment + ")|(" + strings + ")|\\b(" + keywords + ")\\b|\\b([0-9]+(?:\\.[0-9]+)?)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return AttributedString(source) }
        var result = AttributedString(source)
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            let color: Color = match.range(at: 1).location != NSNotFound ? .secondary
                : match.range(at: 2).location != NSNotFound ? .green
                : match.range(at: 3).location != NSNotFound ? .purple : .orange
            result[lower..<upper].foregroundColor = color
        }
        return result
    }
}
