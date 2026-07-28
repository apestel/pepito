import Foundation

/// Vue compacte d'une extraction : **une entrée par conversation**, préfixée par un index `#N`.
///
/// `#N` est la clé de jointure du triage : c'est ce que l'IA reporte dans sa réponse et ce que
/// `MailReport` réutilise. **Ne jamais retrier ni réindexer.** Le digest est la seule chose envoyée
/// à l'IA : métadonnées + 300 caractères d'aperçu, jamais les corps complets.
public enum MailDigest {
    /// Longueur de l'aperçu du dernier message, par conversation.
    static let previewLength = 300

    public static func text(_ r: MailFetchResult) -> String {
        var out = [
            "# \(r.messageCount) messages, \(r.threads.count) conversations — généré "
            + timestamp.string(from: r.generatedAt) + " — période=\(r.period.key)",
            "# index #N = clé du triage (ne pas retrier). ⚑ = flaggé.",
            "# dest N = nombre de destinataires To+Cc du dernier mail (1 = adressé perso, N élevé = diffusion).",
            "",
        ]
        for (i, t) in r.threads.enumerated() {
            var senders: [String] = []
            for m in t.messages where !senders.contains(m.sender) { senders.append(m.sender) }
            let unread = t.messages.filter { !$0.isRead }.count
            let attachments = t.messages.reduce(0) { $0 + $1.attachments }
            let preview = t.last.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            out += [
                "#\(i + 1) \(t.flagged ? "⚑" : " ") \(minute.string(from: t.lastDate)) "
                + "| \(t.messages.count) mail(s) | non-lus \(unread)/\(t.messages.count) "
                + "| PJ \(attachments) | dest \(recipientCount(t.last))",
                "   sujet: \(t.subject)",
                "   de: \(senders.prefix(3).joined(separator: " | "))",
                "   « \(preview.prefix(previewLength)) »",
                "",
            ]
        }
        return out.joined(separator: "\n")
    }

    /// Nombre d'adresses To + Cc du message (1 = adressé personnellement).
    static func recipientCount(_ m: MailMessage) -> Int {
        [m.to, m.cc].reduce(0) { total, field in
            total + field.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        }
    }

    /// « 2026-07-19T18:25:03+0200 » — horodatage de génération, en heure locale.
    static let timestamp = formatter("yyyy-MM-dd'T'HH:mm:ssZ")

    /// « 2026-07-19T18:25 » — même troncature à la minute que le digest d'origine.
    static let minute = formatter("yyyy-MM-dd'T'HH:mm")

    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
