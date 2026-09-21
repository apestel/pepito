import SwiftUI
import Testing
@testable import Pepito

@Test func codeHighlightPreservesLiteralSourceAndDistinguishesTokens() {
    for (language, source) in [
        ("python", "# comment\nif True: print(\"é <tag>\", 42)"),
        ("javascript", "// comment\nconst x = 'é <tag>'; x + 42"),
        ("shell", "# comment\nif true; then echo 'é <tag>' 42; fi")
    ] {
        let result = MissionCodeHighlight.render(source, language: language)
        #expect(String(result.characters) == source)
        #expect(result.runs.contains { $0.foregroundColor == .secondary })
        #expect(result.runs.contains { $0.foregroundColor == .green })
        #expect(result.runs.contains { $0.foregroundColor == .purple })
        #expect(result.runs.contains { $0.foregroundColor == .orange })
    }
    #expect(MissionCodeHighlight.render("<literal>", language: "unknown") == AttributedString("<literal>"))
}
