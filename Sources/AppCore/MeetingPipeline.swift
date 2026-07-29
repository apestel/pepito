import Foundation
import AIKit
import VaultKit
import ActionKit

/// Résultat du traitement d'une réunion.
public struct PipelineResult: Sendable {
    public let finalText: String
    public let actions: [ActionItem]
    public let documentsWritten: [String]
    public let summary: String?
    /// Mises à jour de statut d'actions **ouvertes de réunions passées** que le transcript a permis
    /// de résoudre (suivi cross-réunion, Phase D). À appliquer par l'appelant (accès base).
    public let actionUpdates: [(id: UUID, status: ActionStatus)]
}

/// Analyse d'un transcript en **une seule passe** (aucun appel d'outil) : le modèle renvoie un JSON
/// structuré (résumé + actions hiérarchisées + tags), et l'app écrit le Vault et crée les actions
/// de façon déterministe. Robuste (pas de protocole tool-calling) et compatible avec toutes les
/// gateways OpenAI-compatibles.
public struct MeetingPipeline {
    let provider: any AIProvider
    let vault: Vault

    public init(provider: any AIProvider, vault: Vault) {
        self.provider = provider
        self.vault = vault
    }

    public func process(
        meeting: Meeting,
        transcript: String,
        agenticPrompt: String = PromptTemplate.defaultAgenticPrompt,
        context: String = "",
        userNotes: String = "",
        openActions: String = "",
        projects: [Project] = [],
        userName: String = ""
    ) async throws -> PipelineResult {
        let dateString = Self.dateFormatter.string(from: meeting.startedAt)
        // Le contrat JSON, la liste des projets et l'identité vivent **dans le code**, pas dans
        // `defaultAgenticPrompt` : ce défaut-là est figé dans le settings.json des installations
        // existantes, le modifier ne changerait rien pour elles.
        let systemPrompt = PromptTemplate.render(
            agenticPrompt,
            context: PromptContext(
                transcript: transcript,
                date: dateString,
                participants: meeting.participants.joined(separator: ", "),
                vaultTree: (try? vault.treeOutline()) ?? "",
                context: context,
                userNotes: userNotes,
                openActions: openActions
            )
        ) + "\n\n" + Self.identityBlock(userName)
          + Self.projectsBlock(projects, current: projects.first { $0.id == meeting.projectID })
          + Self.jsonContract

        let reply = try await provider.complete(messages: [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: transcript),
        ])

        let analysis = try Self.parse(reply.content)

        // Construire les plans d'action (aplatir la hiérarchie via parentID) ET rendre le Markdown
        // en une passe, avec l'`id` embarqué en commentaire HTML pour rester reconstructible (§4).
        var actions: [ActionItem] = []
        var planLines: [String] = []
        let projectsByKey = Dictionary(
            projects.map { (Project.matchKey($0.name), $0.id) }, uniquingKeysWith: { a, _ in a })
        func add(_ list: [AnalysisResult.Action], parent: UUID?, depth: Int) {
            for a in list {
                let item = ActionItem(
                    parentID: parent,
                    meetingID: meeting.id,
                    // Projet nommé par le modèle s'il existe, sinon celui de la réunion.
                    projectID: a.project.flatMap { projectsByKey[Project.matchKey($0)] }
                        ?? meeting.projectID,
                    title: a.title,
                    details: a.details ?? "",
                    owner: Self.resolveOwner(a.owner, userName: userName),
                    dueDate: a.dueDate.flatMap(Self.parseDate),
                    priority: Self.parsePriority(a.priority)
                )
                actions.append(item)
                var line = String(repeating: "  ", count: depth) + "- \(item.title)"
                if let owner = item.owner, !owner.isEmpty { line += " (@\(owner))" }
                if let due = a.dueDate, !due.isEmpty { line += " — échéance \(due)" }
                line += " <!-- id:\(item.id.uuidString) -->"
                planLines.append(line)
                add(a.children ?? [], parent: item.id, depth: depth + 1)
            }
        }
        add(analysis.actions ?? [], parent: nil, depth: 0)

        // Tags du summary : ceux saisis par l'utilisateur (prioritaires) + ceux proposés par le
        // modèle, dédupliqués sans casse en conservant l'ordre.
        var seenTags = Set<String>()
        let tags = (meeting.tags + (analysis.tags ?? []))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenTags.insert($0.lowercased()).inserted }

        // Écrire le résumé et le plan d'action dans le Vault.
        var documentsWritten: [String] = []
        if let summary = analysis.summary, !summary.isEmpty {
            let path = PathBuilder.summaryPath(meetingFolder: meeting.folderPath)
            var frontMatter = ["title": meeting.title, "date": dateString]
            if !tags.isEmpty { frontMatter["tags"] = tags.joined(separator: ", ") }
            try? vault.write(VaultDocument(
                relativePath: path,
                type: .summary,
                frontMatter: frontMatter,
                markdown: summary
            ))
            documentsWritten.append(path)
        }
        if !(analysis.actions ?? []).isEmpty {
            let path = PathBuilder.actionPlanPath(meetingFolder: meeting.folderPath)
            try? vault.write(VaultDocument(
                relativePath: path,
                type: .actionPlan,
                frontMatter: ["title": meeting.title, "date": dateString],
                markdown: planLines.joined(separator: "\n")
            ))
            documentsWritten.append(path)
        }

        // Mises à jour de suivi cross-réunion : ne garder que les id/statuts valides.
        let actionUpdates: [(id: UUID, status: ActionStatus)] = (analysis.actionUpdates ?? []).compactMap {
            guard let id = UUID(uuidString: $0.id), let status = ActionStatus(rawValue: $0.status) else { return nil }
            return (id, status)
        }

        return PipelineResult(
            finalText: analysis.summary ?? "",
            actions: actions,
            documentsWritten: documentsWritten,
            summary: analysis.summary,
            actionUpdates: actionUpdates
        )
    }

    // MARK: - Schéma de réponse

    struct AnalysisResult: Decodable {
        struct Action: Decodable {
            let title: String
            let details: String?
            let owner: String?
            let dueDate: String?
            let priority: String?
            let project: String?
            let children: [Action]?

            enum CodingKeys: String, CodingKey {
                case title, details, owner, priority, children, project
                case dueDate = "due_date"
            }
        }
        struct Update: Decodable {
            let id: String
            let status: String
        }
        let summary: String?
        let tags: [String]?
        let actions: [Action]?
        let actionUpdates: [Update]?

        enum CodingKeys: String, CodingKey {
            case summary, tags, actions
            case actionUpdates = "action_updates"
        }
    }

    /// Nom de l'utilisateur : sans lui, le modèle écrit « moi » ou « je » comme responsable, et le
    /// suivi ne sait plus ce qui lui revient.
    static func identityBlock(_ userName: String) -> String {
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        return """
        L'utilisateur qui enregistre s'appelle « \(name) ». Quand une action lui revient (« je »,
        « moi », « de mon côté »), mets EXACTEMENT « \(name) » dans "owner" — jamais « moi ».

        """
    }

    /// Liste des projets ouverts. Le modèle **choisit dedans**, il n'en crée pas : sinon chaque
    /// réunion invente ses propres libellés et le regroupement ne veut plus rien dire.
    /// ponytail: création de projet réservée aux Réglages ; à rouvrir si la saisie manuelle lasse.
    static func projectsBlock(_ projects: [Project], current: Project?) -> String {
        let open = projects.filter { $0.status == .active }
        guard !open.isEmpty else { return "" }
        var s = "Projets existants (à réutiliser tels quels dans \"project\", jamais d'autre nom) :\n"
        s += open.map { "- \($0.name)" }.joined(separator: "\n")
        if let current {
            s += "\nProjet par défaut de cette réunion : « \(current.name) » — mets \"project\": null"
                + " pour l'utiliser."
        }
        return s + "\n\n"
    }

    static let jsonContract = """
    Réponds UNIQUEMENT avec un objet JSON valide de cette forme, sans aucun texte autour :
    {
      "summary": "<résumé de la réunion en Markdown>",
      "tags": ["<mot-clé>"],
      "actions": [
        {"title":"<titre>","details":"<contexte utile pour reprendre l'action plus tard>",
         "owner":"<responsable ou null>",
         "due_date":"<AAAA-MM-JJ ou null>","priority":"high|medium|low",
         "project":"<nom EXACT d'un projet listé ci-dessus, ou null>",
         "children":[ { … même structure pour les sous-tâches … } ]}
      ],
      "action_updates": [
        {"id":"<id EXACT d'une action ouverte fournie ci-dessus que le transcript permet de résoudre>",
         "status":"done|in-progress|blocked|dropped"}
      ]
    }
    Les lignes des notes de l'utilisateur commençant par « - [ ] », « TODO » ou « À faire » sont des
    actions : reprends-les telles quelles dans "actions", sans les reformuler.
    "action_updates" ne concerne QUE les actions ouvertes listées dans le contexte : n'y mets un
    élément que si le transcript indique clairement un changement de statut ; sinon renvoie [].
    """

    /// Le modèle écrit parfois « moi »/« je » malgré la consigne : on rétablit le vrai nom, sinon
    /// l'action est classée « pour info » alors qu'elle m'incombe.
    static func resolveOwner(_ raw: String?, userName: String) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let name = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return trimmed }
        let selfWords = ["moi", "je", "me", "myself", "self", "utilisateur"]
        return selfWords.contains(trimmed.lowercased()) ? name : trimmed
    }

    static func parse(_ content: String) throws -> AnalysisResult {
        let cleaned = stripFences(content)
        guard let data = cleaned.data(using: .utf8) else {
            throw AIError.decoding("contenu non-UTF8")
        }
        do {
            return try JSONDecoder().decode(AnalysisResult.self, from: data)
        } catch {
            throw AIError.decoding("JSON d'analyse invalide : \(error)")
        }
    }

    static func stripFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let range = s.range(of: "```", options: .backwards) {
                s = String(s[..<range.lowerBound])
            }
        }
        // Certains modèles ajoutent du texte : ne garder que du premier { au dernier }.
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}") {
            s = String(s[open...close])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parsePriority(_ raw: String?) -> ActionPriority {
        switch raw?.lowercased() {
        case "high", "haute": return .high
        case "low", "basse": return .low
        default: return .medium
        }
    }

    static func parseDate(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        let short = DateFormatter()
        short.calendar = Calendar(identifier: .gregorian)
        short.locale = Locale(identifier: "en_US_POSIX")
        short.dateFormat = "yyyy-MM-dd"
        return short.date(from: raw)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
