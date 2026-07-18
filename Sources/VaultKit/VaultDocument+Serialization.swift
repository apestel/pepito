extension VaultDocument {
    /// Rend le document au format fichier : bloc front-matter `---` + corps Markdown.
    public func serialized() -> String {
        let fm = FrontMatter.serialize(frontMatter)
        guard !fm.isEmpty else { return markdown }
        return "---\n\(fm)\n---\n\n\(markdown)"
    }

    /// Reconstruit un document depuis le contenu d'un fichier (front-matter optionnel).
    public static func parse(
        relativePath: String,
        type: VaultDocumentType,
        from content: String
    ) -> VaultDocument {
        guard content.hasPrefix("---\n") else {
            return VaultDocument(relativePath: relativePath, type: type, markdown: content)
        }
        let afterOpen = content.dropFirst(4)
        guard let closing = afterOpen.range(of: "\n---\n") ?? afterOpen.range(of: "\n---") else {
            return VaultDocument(relativePath: relativePath, type: type, markdown: content)
        }
        let fmText = String(afterOpen[..<closing.lowerBound])
        var body = String(afterOpen[closing.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return VaultDocument(
            relativePath: relativePath,
            type: type,
            frontMatter: FrontMatter.parse(fmText),
            markdown: body
        )
    }
}
