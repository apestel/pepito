import Foundation
import MailKit

/// Contexte d'interpolation d'un prompt agentic.
public struct PromptContext: Sendable {
    public var transcript: String
    public var date: String
    public var participants: String
    public var vaultTree: String
    /// Contexte réunion : agenda du calendrier + notes de la dernière réunion avec ces participants
    /// (Phase B). Vide si aucun.
    public var context: String
    /// Notes prises par l'utilisateur pendant la réunion, à enrichir plutôt qu'à ignorer (Phase C).
    public var userNotes: String
    /// Actions ouvertes pertinentes (avec leur `id`) à rapprocher du transcript pour l'auto-résolution
    /// du suivi cross-réunion (Phase D). Vide si aucune.
    public var openActions: String

    public init(
        transcript: String, date: String, participants: String, vaultTree: String,
        context: String = "", userNotes: String = "", openActions: String = ""
    ) {
        self.transcript = transcript
        self.date = date
        self.participants = participants
        self.vaultTree = vaultTree
        self.context = context
        self.userNotes = userNotes
        self.openActions = openActions
    }
}

/// Rendu du prompt d'analyse configurable, avec variables `{{…}}` (voir CLAUDE.md §5).
public enum PromptTemplate {
    /// Prompt par défaut fourni à l'utilisateur (éditable dans l'admin). Il n'instruit **que** la
    /// structuration de l'information ; le format de sortie JSON et le rangement dans le Vault sont
    /// gérés par l'app (le modèle n'appelle aucun outil).
    // ponytail: renommage du symbole `defaultAgenticPrompt` = churn sans valeur, on le conserve.
    public static let defaultAgenticPrompt = """
    Tu structures le compte-rendu d'une réunion à partir de son transcript, de son contexte et des
    notes prises par l'utilisateur. Produis :
    1. Un résumé clair (décisions et points clés). **S'il y a des notes utilisateur, pars-en et
       complète-les/corrige-les avec le transcript — ne réécris pas ce que l'humain a déjà noté.**
       Sinon, résume le transcript directement.
    2. Les plans d'action, hiérarchisés (tâches et sous-tâches), avec responsable et échéance
       lorsqu'ils sont mentionnés.
    3. Quelques tags pertinents.

    Date de la réunion : {{date}}. Participants : {{participants}}.
    Contexte (agenda / réunions précédentes) : {{context}}
    Notes de l'utilisateur : {{user_notes}}
    Actions ouvertes de réunions précédentes (résous-les via "action_updates" si le transcript le
    montre — utilise leur id EXACT) : {{open_actions}}
    """

    /// Prompt par défaut du triage de la boîte mail (éditable dans l'admin). Le format de sortie
    /// JSON, le rendu de la revue et la création des actions sont gérés par l'app.
    public static let defaultMailPrompt = """
    Tu tries la boîte mail de l'utilisateur à partir du digest ci-dessous : une entrée par
    conversation, préfixée de son index #N. Analyse **par conversation**, jamais mail par mail.

    Critères d'importance : hiérarchie, client, facture/paiement, urgence explicite, réunion
    imminente, échéance proche, blocage pour quelqu'un d'autre. Tiens compte des signaux du digest :
    « ⚑ » (flaggé par l'utilisateur), les non-lus, le nombre de mails de l'échange, et « dest N »
    (1 = adressé personnellement, donc plus probablement actionnable ; N élevé = diffusion).

    Règles :
    - Ne liste QUE ce qui mérite une attention. Toute conversation absente de ta réponse est
      archivée automatiquement — ne liste pas les newsletters et notifications une par une.
    - Séries identiques (relances répétées, partages en masse) : ne classe que le représentant le
      plus pertinent, laisse les autres non listés.
    - Convertis toute échéance en date absolue AAAA-MM-JJ (« avant vendredi », « le 30 juillet »…) ;
      sinon laisse la chaîne vide. Aujourd'hui : {{date}} (mails triés : {{period}}).

    Actions déjà ouvertes dans Pépito (n'en recrée pas de doublon) : {{open_actions}}
    """

    public static func render(_ template: String, context: PromptContext) -> String {
        template
            .replacingOccurrences(of: "{{transcript}}", with: context.transcript)
            .replacingOccurrences(of: "{{date}}", with: context.date)
            .replacingOccurrences(of: "{{participants}}", with: context.participants)
            .replacingOccurrences(of: "{{vault_tree}}", with: context.vaultTree)
            .replacingOccurrences(of: "{{context}}", with: context.context)
            .replacingOccurrences(of: "{{user_notes}}", with: context.userNotes)
            .replacingOccurrences(of: "{{open_actions}}", with: context.openActions)
    }

    /// Rendu du prompt de triage mail. Variables propres : `{{date}}`, `{{period}}`, `{{days}}`,
    /// `{{open_actions}}` (le digest part en message utilisateur, pas dans le prompt système).
    ///
    /// `{{days}}` reste substitué bien que le prompt par défaut ne l'utilise plus : les prompts
    /// déjà enregistrés dans `settings.json` le contiennent, et rien dans l'UI ne les réinitialise.
    public static func renderMail(
        _ template: String, date: String, period: MailPeriod, openActions: String
    ) -> String {
        template
            .replacingOccurrences(of: "{{date}}", with: date)
            .replacingOccurrences(of: "{{period}}", with: period.label)
            .replacingOccurrences(of: "{{days}}", with: String(period.dayCount))
            .replacingOccurrences(of: "{{open_actions}}", with: openActions)
    }
}
