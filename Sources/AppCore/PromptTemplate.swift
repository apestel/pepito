import Foundation

/// Contexte d'interpolation d'un prompt agentic.
public struct PromptContext: Sendable {
    public var transcript: String
    public var date: String
    public var participants: String
    public var vaultTree: String

    public init(transcript: String, date: String, participants: String, vaultTree: String) {
        self.transcript = transcript
        self.date = date
        self.participants = participants
        self.vaultTree = vaultTree
    }
}

/// Rendu du prompt d'analyse configurable, avec variables `{{…}}` (voir CLAUDE.md §5).
public enum PromptTemplate {
    /// Prompt par défaut fourni à l'utilisateur (éditable dans l'admin). Il n'instruit **que** la
    /// structuration de l'information ; le format de sortie JSON et le rangement dans le Vault sont
    /// gérés par l'app (le modèle n'appelle aucun outil).
    // ponytail: renommage du symbole `defaultAgenticPrompt` = churn sans valeur, on le conserve.
    public static let defaultAgenticPrompt = """
    Tu structures le compte-rendu d'une réunion à partir de son transcript. Produis :
    1. Un résumé clair (décisions et points clés).
    2. Les plans d'action, hiérarchisés (tâches et sous-tâches), avec responsable et échéance
       lorsqu'ils sont mentionnés.
    3. Quelques tags pertinents.
    Date de la réunion : {{date}}. Participants : {{participants}}.
    """

    public static func render(_ template: String, context: PromptContext) -> String {
        template
            .replacingOccurrences(of: "{{transcript}}", with: context.transcript)
            .replacingOccurrences(of: "{{date}}", with: context.date)
            .replacingOccurrences(of: "{{participants}}", with: context.participants)
            .replacingOccurrences(of: "{{vault_tree}}", with: context.vaultTree)
    }
}
