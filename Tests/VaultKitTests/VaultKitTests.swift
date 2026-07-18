import Testing
import Foundation
@testable import VaultKit

@Test func moduleIdentity() {
    #expect(VaultKit.moduleName == "VaultKit")
}

@Test func documentTypeRawValues() {
    #expect(VaultDocumentType.actionPlan.rawValue == "action-plan")
    #expect(VaultDocumentType.meetingNote.rawValue == "meeting-note")
}

// MARK: - Front matter

@Test func frontMatterRoundTrip() {
    let dict = ["date": "2026-07-15", "title": "Weekly Sync", "tags": "a, b"]
    let text = FrontMatter.serialize(dict)
    #expect(FrontMatter.parse(text) == dict)
}

@Test func frontMatterQuotesValuesWithColons() {
    let text = FrontMatter.serialize(["url": "https://example.com:8080"])
    #expect(text.contains("\""))
    #expect(FrontMatter.parse(text)["url"] == "https://example.com:8080")
}

@Test func emptyFrontMatterSerializesEmpty() {
    #expect(FrontMatter.serialize([:]) == "")
}

// MARK: - Document serialization

@Test func documentSerializationRoundTrip() {
    let doc = VaultDocument(
        relativePath: "2026/07/15-sync/notes.md",
        type: .meetingNote,
        frontMatter: ["date": "2026-07-15", "title": "Sync"],
        markdown: "# Sync\n\nTexte du corps."
    )
    let parsed = VaultDocument.parse(
        relativePath: doc.relativePath,
        type: .meetingNote,
        from: doc.serialized()
    )
    #expect(parsed.frontMatter == doc.frontMatter)
    #expect(parsed.markdown == doc.markdown)
}

@Test func documentWithoutFrontMatterParses() {
    let parsed = VaultDocument.parse(relativePath: "x.md", type: .summary, from: "# Titre seul")
    #expect(parsed.frontMatter.isEmpty)
    #expect(parsed.markdown == "# Titre seul")
}

// MARK: - Path building

@Test func slugifyNormalizes() {
    #expect(PathBuilder.slugify("Weekly Sync!!  2026") == "weekly-sync-2026")
    #expect(PathBuilder.slugify("---") == "sans-titre")
}

@Test func meetingFolderConvention() {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 7; comps.day = 15
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let date = cal.date(from: comps)!
    let folder = PathBuilder.meetingFolder(date: date, title: "Weekly Sync", calendar: cal)
    #expect(folder == "2026/07/15-weekly-sync")
}

// MARK: - Filesystem

@Test func vaultWriteReadListRoundTrip() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-vault-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let vault = Vault(root: tmp)
    let doc = VaultDocument(
        relativePath: "2026/07/15-sync/summary.md",
        type: .summary,
        frontMatter: ["title": "Sync"],
        markdown: "## Résumé\n\n- point 1"
    )
    try vault.write(doc)
    #expect(vault.exists(relativePath: doc.relativePath))

    let read = try vault.read(relativePath: doc.relativePath, type: .summary)
    #expect(read.markdown == doc.markdown)
    #expect(read.frontMatter["title"] == "Sync")

    let files = try vault.listMarkdownFiles()
    #expect(files == ["2026/07/15-sync/summary.md"])
}
