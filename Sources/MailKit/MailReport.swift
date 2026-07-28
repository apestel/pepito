import Foundation

/// Rendu **déterministe** de la revue Markdown à partir de (extraction, triage).
/// L'IA ne produit que le jugement : liens `message://`, regroupement, comptes, sections, tri de la
/// todo et archive sont calculés ici.
public enum MailReport {
    /// Actions qui alimentent la todo — et donc les plans d'action de Pépito.
    public static let todoActions: Set<String> = ["Répondre", "Décider", "Suivre"]

    static let importanceRank = ["Critique": 0, "Haute": 1, "Normale": 2, "Faible": 3]

    /// Revue rendue + les items retenus (appariés à leur conversation) pour créer les actions.
    public struct Rendered: Sendable {
        public let markdown: String
        /// Items valides, dans l'ordre du rapport, avec la conversation correspondante.
        public let items: [(item: MailTriageItem, thread: MailThread)]
        /// `id` reçus mais hors limites ou en double — signalés, pas rendus.
        public let ignoredIDs: [Int]
    }

    public static func render(result: MailFetchResult, triage: MailTriage, today: Date = Date()) -> Rendered {
        let threads = result.threads

        // Dernière occurrence gardée en cas de doublon, comme le rendu d'origine.
        var byID: [Int: MailTriageItem] = [:]
        var ignored: [Int] = []
        for it in triage.items {
            guard (1...threads.count).contains(it.id) else { ignored.append(it.id); continue }
            if byID[it.id] != nil { ignored.append(it.id) }
            byID[it.id] = it
        }

        func thread(_ i: Int) -> MailThread { threads[i - 1] }
        func link(_ i: Int) -> String { "[\(thread(i).subject)](\(thread(i).last.url))" }
        func who(_ i: Int) -> String { senderName(thread(i).last.sender) }

        var lines = [
            "# Revue des mails — \(result.period.label)", "",
            "_\(result.messageCount) messages, \(threads.count) conversations analysées le "
            + "\(dayFormatter.string(from: today))._", "",
        ]

        var ordered: [(item: MailTriageItem, thread: MailThread)] = []
        for bucket in MailBucket.allCases {
            let ids = byID.keys.filter { byID[$0]?.bucket == bucket }.sorted { a, b in
                let (x, y) = (byID[a]!, byID[b]!)
                if deadlineKey(x.deadline) != deadlineKey(y.deadline) {
                    return deadlineKey(x.deadline) < deadlineKey(y.deadline)
                }
                let (ra, rb) = (importanceRank[x.importance] ?? 9, importanceRank[y.importance] ?? 9)
                return ra != rb ? ra < rb : a < b
            }
            guard !ids.isEmpty else { continue }
            ordered += ids.map { (byID[$0]!, thread($0)) }

            lines += ["## \(bucket.title) (\(ids.count))", ""]
            if bucket == .info {
                lines += ids.map { "- \(link($0)) — \(who($0)) — \(byID[$0]!.summary)" }
                lines.append("")
            } else {
                for (n, i) in ids.enumerated() {
                    let it = byID[i]!
                    let count = thread(i).messages.count > 1 ? " (\(thread(i).messages.count) mails)" : ""
                    let flag = thread(i).flagged ? " ⚑" : ""
                    lines += [
                        "### \(n + 1). \(link(i)) — \(who(i))\(count)\(flag)",
                        "- **Importance** : \(it.importance.isEmpty ? "—" : it.importance)"
                        + " — **Action** : \(it.action.isEmpty ? "—" : it.action)"
                        + " — **Échéance** : \(it.deadline.isEmpty ? "—" : it.deadline)",
                    ]
                    if !it.why.isEmpty { lines.append("- **Pourquoi** : \(it.why)") }
                    if !it.summary.isEmpty { lines.append("- **Résumé** : \(it.summary)") }
                    lines.append("")
                }
            }
        }

        // ⚪ archive = tout ce qui n'est pas classé, regroupé par expéditeur.
        let archived = threads.indices.map { $0 + 1 }.filter { byID[$0] == nil }
        if !archived.isEmpty {
            var counts: [String: Int] = [:]
            for i in archived { counts[who(i), default: 0] += 1 }
            lines += ["## ⚪ Peut être archivé (\(archived.count))", ""]
            var singles = 0
            for (sender, n) in counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
                if n > 1 { lines.append("- \(sender) ×\(n)") } else { singles += 1 }
            }
            if singles > 0 {
                let s = singles > 1 ? "s" : ""
                lines.append("- _+ \(singles) autre\(s) expéditeur\(s) (1 message chacun)_")
            }
            lines.append("")
        }

        // ✅ todo : actions Répondre / Décider / Suivre, triées par échéance.
        let todos = ordered.filter { todoActions.contains($0.item.action) }
            .sorted { deadlineKey($0.item.deadline) < deadlineKey($1.item.deadline) }
        if !todos.isEmpty {
            lines += ["## ✅ Todo list", ""]
            for (item, thread) in todos {
                let due = item.deadline.isEmpty ? "" : " (échéance \(item.deadline))"
                lines.append("- [ ] \(todoLabel(item, thread: thread))\(due)")
            }
            lines.append("")
        }

        return Rendered(markdown: lines.joined(separator: "\n"), items: ordered, ignoredIDs: ignored)
    }

    /// Libellé de todo : celui fourni par l'IA, sinon `action : sujet`.
    public static func todoLabel(_ item: MailTriageItem, thread: MailThread) -> String {
        item.todo.isEmpty ? "\(item.action) : \(thread.subject)" : item.todo
    }

    /// « Nom <mail> » → Nom ; sinon l'adresse ; sinon la chaîne brute.
    static func senderName(_ s: String) -> String {
        var name = s
        if let m = s.firstMatch(of: #/\s*"?([^"<]+?)"?\s*</#) {
            name = String(m.output.1)
        } else if let m = s.firstMatch(of: #/<([^>]+)>/#) {
            name = String(m.output.1)
        } else if let m = s.firstMatch(of: #/^\s*(\S+@\S+)/#) {
            name = String(m.output.1)
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "(inconnu)" : trimmed
    }

    /// Datés (`AAAA-MM-JJ`) d'abord et triés ; texte libre ou vide à la fin.
    static func deadlineKey(_ deadline: String) -> (Int, String) {
        deadline.firstMatch(of: #/^\d{4}-\d{2}-\d{2}/#) != nil ? (0, deadline) : (1, "")
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
