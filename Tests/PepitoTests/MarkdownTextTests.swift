import SwiftUI
import Testing
@testable import Pepito

@Test func markdownPreservesBlockStructureAndInlineFormatting() throws {
    let blocks = MarkdownBlock.parse("""
        # Titre **fort**

        Un *mot*, **gras**, ~~barré~~, `a < b` et [un lien](https://example.com).

        | Nom | Centre | Total |
        | :--- | :---: | ---: |
        | **Alpha** | *milieu* | 42 |
        | | vide à gauche | |

        > Citation
        >
        > - Élément
        >   1. Sous-élément

        3. Trois
        4. Quatre

        ```swift
        # littéral **sans gras**
          let value = "<tag> | texte"
        ```

        ---
        """)
    #expect(blocks.count == 7)
    #expect(blocks[0].kind == .header(level: 1))
    #expect(String(blocks[0].text.characters) == "Titre fort")
    let inline = blocks[1].text
    #expect(inline.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
    #expect(inline.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(inline.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    #expect(inline.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil })
    #expect(inline.runs.contains { $0.link?.absoluteString == "https://example.com" })
    guard case .table(let columns) = blocks[2].kind else {
        Issue.record("Expected a Markdown table")
        return
    }
    #expect(columns.map(\.alignment) == [.left, .center, .right])
    let rows = blocks[2].children
    #expect(rows.count == 3)
    #expect(rows[0].kind == .tableHeaderRow)
    #expect(String(rows[1].cell(at: 2).characters) == "42")
    #expect(rows[1].cell(at: 0).runs.first?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    #expect(rows[2].cell(at: 0).characters.isEmpty)
    #expect(String(rows[2].cell(at: 1).characters) == "vide à gauche")
    #expect(rows[2].cell(at: 2).characters.isEmpty)
    #expect(blocks[3].kind == .blockQuote)
    #expect(blocks[3].children[1].kind == .unorderedList)
    #expect(blocks[3].children[1].children[0].children[1].kind == .orderedList)
    #expect(blocks[4].children.map(\.kind) == [.listItem(ordinal: 3), .listItem(ordinal: 4)])
    #expect(blocks[5].kind == .codeBlock(languageHint: "swift"))
    #expect(String(blocks[5].text.characters) == "# littéral **sans gras**\n  let value = \"<tag> | texte\"\n")
    #expect(blocks[6].kind == .thematicBreak)

    // A streamed response can end inside a fence, inline markup, or a table row.
    for source in ["```swift\nlet a = 1", "Texte **inachevé", "| A | B |\n|---|---|\n| x |"] {
        #expect(!MarkdownBlock.parse(source).isEmpty)
    }
    #expect(MarkdownBlock.parse("").isEmpty)
}
