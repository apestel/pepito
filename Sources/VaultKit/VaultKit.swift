import Foundation

/// Arborescence documentaire locale (Markdown + front-matter YAML). Implémentation Phase 3.
/// Le Vault est la source de vérité du contenu ; l'index base est reconstructible.
public enum VaultKit {
    public static let moduleName = "VaultKit"
}

/// Type de document rangé dans le Vault.
public enum VaultDocumentType: String, Sendable, CaseIterable, Codable {
    case meetingNote = "meeting-note"
    case summary
    case actionPlan = "action-plan"
    case index
}

/// Document du Vault : chemin relatif + front-matter + corps Markdown.
public struct VaultDocument: Sendable, Equatable {
    public var relativePath: String
    public var type: VaultDocumentType
    public var frontMatter: [String: String]
    public var markdown: String

    public init(
        relativePath: String,
        type: VaultDocumentType,
        frontMatter: [String: String] = [:],
        markdown: String
    ) {
        self.relativePath = relativePath
        self.type = type
        self.frontMatter = frontMatter
        self.markdown = markdown
    }
}
