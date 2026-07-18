import Foundation

/// Accès système de fichiers au Vault documentaire. Écritures atomiques, création de dossiers.
/// Le Vault est la source de vérité du contenu (CLAUDE.md §4).
public struct Vault: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func url(for relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    public func exists(relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: relativePath).path)
    }

    /// Écrit (ou remplace) un document de façon atomique, en créant les dossiers manquants.
    public func write(_ document: VaultDocument) throws {
        let fileURL = url(for: document.relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(document.serialized().utf8).write(to: fileURL, options: .atomic)
    }

    public func read(
        relativePath: String,
        type: VaultDocumentType = .meetingNote
    ) throws -> VaultDocument {
        let content = try String(contentsOf: url(for: relativePath), encoding: .utf8)
        return VaultDocument.parse(relativePath: relativePath, type: type, from: content)
    }

    /// Liste récursive des fichiers Markdown, en chemins relatifs triés (pour l'indexation).
    public func listMarkdownFiles() throws -> [String] {
        let base = root.resolvingSymlinksInPath()
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: nil
        ) else { return [] }

        var results: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "md" {
            let resolved = fileURL.resolvingSymlinksInPath().path
            if resolved.hasPrefix(prefix) {
                results.append(String(resolved.dropFirst(prefix.count)))
            } else {
                results.append(fileURL.lastPathComponent)
            }
        }
        return results.sorted()
    }

    /// Représentation arborescente compacte du Vault, utile comme contexte `{{vault_tree}}` pour l'IA.
    public func treeOutline() throws -> String {
        try listMarkdownFiles().joined(separator: "\n")
    }
}
