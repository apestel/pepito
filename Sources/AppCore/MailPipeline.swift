import Foundation
import CryptoKit
import AIKit
import VaultKit
import ActionKit
import MailKit

/// Résultat d'un triage : la revue écrite dans le Vault et les actions à persister.
public struct MailTriageResult: Sendable {
    public let reportPath: String
    public let actions: [ActionItem]
    /// Toutes les conversations triées, à persister pour l'historique consultable dans l'app.
    public let entries: [MailReviewEntry]
    public let threadCount: Int
    public let messageCount: Int
    /// `id` renvoyés par le modèle mais hors limites (diagnostic ; non bloquant).
    public let ignoredIDs: [Int]
}

/// Triage de la boîte mail en **une seule passe** (aucun appel d'outil), sur le même modèle que
/// `MeetingPipeline` : le digest part vers l'IA, qui renvoie un JSON de jugement ; l'app rend la
/// revue Markdown et crée les plans d'action de façon déterministe.
///
/// Seul le **digest** (métadonnées + 300 caractères d'aperçu par conversation) est envoyé à
/// l'endpoint — jamais les corps complets.
public struct MailPipeline {
    let provider: any AIProvider
    let vault: Vault

    public init(provider: any AIProvider, vault: Vault) {
        self.provider = provider
        self.vault = vault
    }

    public func process(
        result: MailFetchResult,
        prompt: String = PromptTemplate.defaultMailPrompt,
        openActions: String = "",
        today: Date = Date()
    ) async throws -> MailTriageResult {
        let digest = MailDigest.text(result)
        let systemPrompt = PromptTemplate.renderMail(
            prompt,
            date: MeetingPipeline.dateFormatter.string(from: today),
            days: result.days,
            openActions: openActions
        ) + "\n\n" + Self.jsonContract

        let reply = try await provider.complete(messages: [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: digest),
        ])

        let triage = try Self.parse(reply.content)
        let rendered = MailReport.render(result: result, triage: triage, today: today)

        let path = PathBuilder.mailReportPath(date: today)
        try vault.write(VaultDocument(
            relativePath: path,
            type: .summary,
            frontMatter: [
                "title": "Revue des mails",
                "date": MeetingPipeline.dateFormatter.string(from: today),
                "tags": "mail",
            ],
            markdown: rendered.markdown))

        // Les actions gardent l'index `#N` de leur conversation : c'est ce qui relie une ligne de la
        // revue à l'action éditable qu'elle a produite.
        var actions: [ActionItem] = []
        var actionIDs: [Int: UUID] = [:]
        for entry in rendered.items where MailReport.todoActions.contains(entry.item.action) {
            let action = ActionItem(
                id: Self.actionID(for: entry.thread),
                title: MailReport.todoLabel(entry.item, thread: entry.thread),
                details: entry.item.summary,
                dueDate: entry.item.deadline.isEmpty ? nil : MeetingPipeline.parseDate(entry.item.deadline),
                priority: Self.priority(entry.item.importance),
                sourceURL: entry.thread.last.url.isEmpty ? nil : entry.thread.last.url)
            actions.append(action)
            actionIDs[entry.item.id] = action.id
        }

        return MailTriageResult(
            reportPath: path,
            actions: actions,
            entries: MailReview.entries(
                result: result, triage: triage,
                date: MeetingPipeline.dateFormatter.string(from: today), actionIDs: actionIDs),
            threadCount: result.threads.count,
            messageCount: result.messageCount,
            ignoredIDs: rendered.ignoredIDs)
    }

    // MARK: - Identité stable des actions

    /// Identifiant **déterministe** dérivé du `Message-ID` du dernier mail de la conversation (à
    /// défaut, du sujet). Retrier la même période ne duplique donc pas les actions : `saveActions`
    /// met à jour la ligne existante et **préserve le statut** déjà suivi.
    static func actionID(for thread: MailThread) -> UUID {
        let seed = thread.last.id.isEmpty ? "subject:\(thread.subject)" : thread.last.id
        var bytes = Array(SHA256.hash(data: Data("pepito-mail:\(seed)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50          // version 5 (nom + espace de noms)
        bytes[8] = (bytes[8] & 0x3F) | 0x80          // variante RFC 4122
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6],
                           bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12],
                           bytes[13], bytes[14], bytes[15]))
    }

    static func priority(_ importance: String) -> ActionPriority {
        switch importance.lowercased() {
        case "critique", "haute": .high
        case "faible": .low
        default: .medium
        }
    }

    // MARK: - Contrat de réponse

    static let jsonContract = """
    Réponds UNIQUEMENT avec un objet JSON valide de cette forme, sans aucun texte autour :
    {
      "period": "<libellé de la période, ex. semaine du 13 au 19 juillet 2026>",
      "date": "<AAAA-MM-JJ du jour>",
      "items": [
        {"id": <index #N du digest>, "bucket": "immediate|week|info",
         "importance": "Critique|Haute|Normale|Faible",
         "action": "Répondre|Décider|Lire|Archiver|Suivre|Aucune",
         "deadline": "<AAAA-MM-JJ ou chaîne vide>",
         "why": "<une ligne justifiant le classement>",
         "summary": "<2-3 lignes : où en est l'échange, quelle est la dernière demande>",
         "todo": "<libellé impératif pour la todo, optionnel>"}
      ]
    }
    Répartition des buckets : "immediate" = Critique ou échéance ≤ 48 h ; "week" = Haute ou échéance
    cette semaine ; "info" = à lire, pas d'action bloquante.
    """

    static func parse(_ content: String) throws -> MailTriage {
        guard let data = MeetingPipeline.stripFences(content).data(using: .utf8) else {
            throw AIError.decoding("contenu non-UTF8")
        }
        do {
            return try JSONDecoder().decode(MailTriage.self, from: data)
        } catch {
            throw AIError.decoding("JSON de triage invalide : \(error)")
        }
    }
}
