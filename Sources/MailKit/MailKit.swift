import Foundation

/// Triage de la boîte mail (Mail.app) : extraction, digest compact, rendu de la revue.
/// Le **jugement** (classement par priorité) n'est PAS ici : il vient de l'IA, via
/// `MailPipeline` dans AppCore. Ce Kit ne contient que du déterministe et du testable.
public enum MailKit {
    public static let moduleName = "MailKit"
}

/// Un message extrait de Mail.app.
public struct MailMessage: Sendable, Equatable {
    /// `Message-ID` RFC 822 (peut être vide sur des messages exotiques).
    public let id: String
    /// Lien `message://…` ouvrable dans Mail.
    public let url: String
    public let subject: String
    public let sender: String
    public let to: String
    public let cc: String
    public let date: Date
    public let mailbox: String
    public let isRead: Bool
    public let flagged: Bool
    public let attachments: Int
    /// Corps texte décodé (tronqué à `bodyChars`).
    public let body: String

    public init(
        id: String, url: String, subject: String, sender: String, to: String, cc: String,
        date: Date, mailbox: String, isRead: Bool, flagged: Bool, attachments: Int, body: String
    ) {
        self.id = id
        self.url = url
        self.subject = subject
        self.sender = sender
        self.to = to
        self.cc = cc
        self.date = date
        self.mailbox = mailbox
        self.isRead = isRead
        self.flagged = flagged
        self.attachments = attachments
        self.body = body
    }
}

/// Conversation : messages d'un même sujet normalisé, du plus ancien au plus récent.
public struct MailThread: Sendable, Equatable {
    public let subject: String
    public let messages: [MailMessage]

    public init(subject: String, messages: [MailMessage]) {
        self.subject = subject
        self.messages = messages
    }

    /// Dernier message de la conversation (celui qui porte l'état courant de l'échange).
    public var last: MailMessage { messages[messages.count - 1] }
    public var lastDate: Date { last.date }
    /// Au moins un message flaggé par l'utilisateur.
    public var flagged: Bool { messages.contains(where: \.flagged) }
}

/// Période couverte par une revue : jours calendaires **inclusifs** (`AAAA-MM-JJ`).
///
/// Sa `key` est l'identité de la revue partout : clé SQLite (`mail_item.review_date`), nom du
/// document dans le Vault, sélection de la barre latérale. Un seul jour → `2026-07-27` ; un
/// intervalle → `2026-07-21_2026-07-27`. Les revues d'avant cette notion sont enregistrées sous
/// leur jour de lancement : elles se relisent comme des périodes d'un jour.
public struct MailPeriod: Hashable, Sendable {
    /// Premier jour couvert, inclus.
    public let start: String
    /// Dernier jour couvert, inclus.
    public let end: String

    public var key: String { start == end ? start : "\(start)_\(end)" }

    public init(start: Date, end: Date, calendar: Calendar = .current) {
        let (a, b) = start <= end ? (start, end) : (end, start)
        self.start = Self.day(a, calendar)
        self.end = Self.day(b, calendar)
    }

    /// Relit une clé de période. `nil` si le format n'est pas reconnu (donnée corrompue).
    public init?(key: String) {
        let parts = key.split(separator: "_", maxSplits: 1).map(String.init)
        guard let first = parts.first, Self.components(first) != nil else { return nil }
        let last = parts.count > 1 ? parts[1] : first
        guard Self.components(last) != nil else { return nil }
        start = first
        end = last
    }

    /// « 27 juil. » pour un jour, « 21–27 juil. » pour un intervalle (le style d'intervalle de
    /// Foundation factorise déjà le mois quand il est commun). Repli sur la clé brute si le
    /// format est inattendu.
    public var label: String {
        guard let s = Self.date(start), let e = Self.date(end) else { return key }
        return s == e
            ? s.formatted(.dateTime.day().month(.abbreviated))
            : (s..<e).formatted(.interval.day().month(.abbreviated))
    }

    /// Bornes réelles de l'extraction : minuit du premier jour → minuit du **lendemain** du
    /// dernier (borne haute exclusive). C'est ce qui rend « Aujourd'hui » = depuis minuit, et non
    /// « les 24 dernières heures ».
    public func bounds(calendar: Calendar = .current) -> (start: Date, endExclusive: Date) {
        let from = Self.date(start, calendar) ?? Date()
        let lastDay = Self.date(end, calendar) ?? from
        let to = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        return (from, to)
    }

    /// Nombre de jours couverts (1 pour un jour seul).
    public var dayCount: Int {
        guard let s = Self.date(start), let e = Self.date(end) else { return 1 }
        return (Calendar.current.dateComponents([.day], from: s, to: e).day ?? 0) + 1
    }

    // MARK: - Périodes usuelles (celles proposées dans l'UI)

    public static func today(_ now: Date = Date(), calendar: Calendar = .current) -> MailPeriod {
        MailPeriod(start: now, end: now, calendar: calendar)
    }

    public static func yesterday(_ now: Date = Date(), calendar: Calendar = .current) -> MailPeriod {
        let d = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        return MailPeriod(start: d, end: d, calendar: calendar)
    }

    /// Les `days` derniers jours, aujourd'hui compris (`lastDays(7)` = aujourd'hui + 6 jours avant).
    public static func lastDays(_ days: Int, now: Date = Date(), calendar: Calendar = .current) -> MailPeriod {
        let from = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: now) ?? now
        return MailPeriod(start: from, end: now, calendar: calendar)
    }

    /// Semaine calendaire en cours, de son premier jour à aujourd'hui (pas de futur à trier).
    public static func thisWeek(_ now: Date = Date(), calendar: Calendar = .current) -> MailPeriod {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return today(now, calendar: calendar) }
        return MailPeriod(start: week.start, end: now, calendar: calendar)
    }

    /// Semaine calendaire précédente, complète.
    public static func lastWeek(_ now: Date = Date(), calendar: Calendar = .current) -> MailPeriod {
        guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
              let week = calendar.dateInterval(of: .weekOfYear, for: previous)
        else { return yesterday(now, calendar: calendar) }
        // `week.end` est minuit du lundi suivant : le dernier jour couvert est la veille.
        let last = calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.start
        return MailPeriod(start: week.start, end: last, calendar: calendar)
    }

    // MARK: - Conversions jour ↔ date
    //
    // Pas de `DateFormatter` ici : son fuseau est celui de la machine, alors que les bornes sont
    // calculées dans le calendrier qu'on lui passe. Les deux finiraient par diverger d'un jour.

    static func day(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func components(_ day: String) -> DateComponents? {
        let p = day.split(separator: "-")
        guard p.count == 3, p[0].count == 4,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }

    /// Minuit du jour, dans le calendrier donné.
    static func date(_ day: String, _ calendar: Calendar = .current) -> Date? {
        components(day).flatMap { calendar.date(from: $0) }
    }
}

/// Résultat d'une extraction : conversations les plus récentes en tête.
public struct MailFetchResult: Sendable, Equatable {
    public let generatedAt: Date
    /// Période demandée (jours calendaires), telle qu'elle identifiera la revue.
    public let period: MailPeriod
    public let messageCount: Int
    public let threads: [MailThread]

    public init(generatedAt: Date, period: MailPeriod, messageCount: Int, threads: [MailThread]) {
        self.generatedAt = generatedAt
        self.period = period
        self.messageCount = messageCount
        self.threads = threads
    }
}

/// Erreurs d'extraction. `automationDenied` est le cas courant au premier lancement.
public enum MailError: LocalizedError, Equatable {
    case automationDenied
    case appleScript(String)

    public var errorDescription: String? {
        switch self {
        case .automationDenied:
            "Pépito n'a pas l'autorisation de piloter Mail. Réglages Système › Confidentialité et "
            + "sécurité › Automatisation › Pépito › activer Mail."
        case .appleScript(let message):
            "Extraction des mails impossible : \(message)"
        }
    }
}
