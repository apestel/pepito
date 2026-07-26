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

/// Résultat d'une extraction : conversations les plus récentes en tête.
public struct MailFetchResult: Sendable, Equatable {
    public let generatedAt: Date
    public let days: Int
    public let messageCount: Int
    public let threads: [MailThread]

    public init(generatedAt: Date, days: Int, messageCount: Int, threads: [MailThread]) {
        self.generatedAt = generatedAt
        self.days = days
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
