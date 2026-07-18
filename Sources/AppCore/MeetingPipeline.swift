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
        agenticPrompt: String = PromptTemplate.defaultAgenticPrompt
    ) async throws -> PipelineResult {
        let dateString = Self.dateFormatter.string(from: meeting.startedAt)
        let systemPrompt = PromptTemplate.render(
            agenticPrompt,
            context: PromptContext(
                transcript: transcript,
                date: dateString,
                participants: meeting.participants.joined(separator: ", "),
                vaultTree: (try? vault.treeOutline()) ?? ""
            )
        ) + "\n\n" + Self.jsonContract

        let reply = try await provider.complete(messages: [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: transcript),
        ])

        let analysis = try Self.parse(reply.content)

        // Construire les plans d'action (aplatir la hiérarchie via parentID).
        var actions: [ActionItem] = []
        func add(_ list: [AnalysisResult.Action], parent: UUID?) {
            for a in list {
                let item = ActionItem(
                    parentID: parent,
                    meetingID: meeting.id,
                    title: a.title,
                    details: a.details ?? "",
                    owner: a.owner,
                    dueDate: a.dueDate.flatMap(Self.parseDate),
                    priority: Self.parsePriority(a.priority)
                )
                actions.append(item)
                add(a.children ?? [], parent: item.id)
            }
        }
        add(analysis.actions ?? [], parent: nil)

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
                markdown: Self.renderActionPlan(analysis.actions ?? [], depth: 0)
            ))
            documentsWritten.append(path)
        }

        return PipelineResult(
            finalText: analysis.summary ?? "",
            actions: actions,
            documentsWritten: documentsWritten,
            summary: analysis.summary
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
            let children: [Action]?

            enum CodingKeys: String, CodingKey {
                case title, details, owner, priority, children
                case dueDate = "due_date"
            }
        }
        let summary: String?
        let tags: [String]?
        let actions: [Action]?
    }

    static let jsonContract = """
    Réponds UNIQUEMENT avec un objet JSON valide de cette forme, sans aucun texte autour :
    {
      "summary": "<résumé de la réunion en Markdown>",
      "tags": ["<mot-clé>"],
      "actions": [
        {"title":"<titre>","details":"<détails>","owner":"<responsable ou null>",
         "due_date":"<AAAA-MM-JJ ou null>","priority":"high|medium|low",
         "children":[ { … même structure pour les sous-tâches … } ]}
      ]
    }
    """

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

    static func renderActionPlan(_ list: [AnalysisResult.Action], depth: Int) -> String {
        list.map { action -> String in
            let indent = String(repeating: "  ", count: depth)
            var line = "\(indent)- \(action.title)"
            if let owner = action.owner, !owner.isEmpty { line += " (@\(owner))" }
            if let due = action.dueDate, !due.isEmpty { line += " — échéance \(due)" }
            if let children = action.children, !children.isEmpty {
                line += "\n" + renderActionPlan(children, depth: depth + 1)
            }
            return line
        }.joined(separator: "\n")
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
