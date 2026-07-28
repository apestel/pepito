import Foundation

/// Une conversation telle qu'elle a été triée ce jour-là. C'est de l'**historique** : le contenu est
/// figé au moment de la revue (le sujet ou l'expéditeur peuvent changer dans Mail par la suite),
/// seule l'action liée reste vivante via `actionID`.
public struct MailReviewEntry: Sendable, Equatable, Identifiable {
    /// Clé de la période couverte — `AAAA-MM-JJ` ou `AAAA-MM-JJ_AAAA-MM-JJ` (cf. `MailPeriod.key`).
    /// C'est la clé d'historique : retrier la même période remplace la revue.
    public let reviewDate: String
    /// Index `#N` du digest — l'ordre d'origine, jamais réattribué.
    public let index: Int
    public let subject: String
    /// Nom affichable de l'expéditeur (déjà résolu, cf. `MailReport.senderName`).
    public let sender: String
    /// Lien `message://` ouvrable dans Mail.
    public let url: String
    public let messageCount: Int
    public let unread: Int
    public let flagged: Bool
    /// `nil` = conversation non classée par l'IA, donc archivable (⚪).
    public let bucket: MailBucket?
    public let importance: String
    public let action: String
    public let deadline: String
    public let why: String
    public let summary: String
    /// `ActionItem` créé pour cette conversation, s'il y en a un.
    public let actionID: UUID?

    public var id: String { "\(reviewDate)#\(index)" }

    public init(
        reviewDate: String, index: Int, subject: String, sender: String, url: String,
        messageCount: Int, unread: Int, flagged: Bool, bucket: MailBucket?,
        importance: String = "", action: String = "", deadline: String = "",
        why: String = "", summary: String = "", actionID: UUID? = nil
    ) {
        self.reviewDate = reviewDate
        self.index = index
        self.subject = subject
        self.sender = sender
        self.url = url
        self.messageCount = messageCount
        self.unread = unread
        self.flagged = flagged
        self.bucket = bucket
        self.importance = importance
        self.action = action
        self.deadline = deadline
        self.why = why
        self.summary = summary
        self.actionID = actionID
    }
}

/// Ligne d'historique : ce qu'il faut pour afficher une revue dans la barre latérale sans charger
/// toutes ses conversations.
public struct MailReviewSummary: Sendable, Equatable, Identifiable {
    /// Clé de la période couverte (cf. `MailReviewEntry.reviewDate`).
    public let date: String
    public let messageCount: Int
    public let threadCount: Int
    public let immediateCount: Int
    public let flaggedCount: Int
    public let actionCount: Int

    public var id: String { date }

    public init(
        date: String, messageCount: Int, threadCount: Int,
        immediateCount: Int, flaggedCount: Int, actionCount: Int
    ) {
        self.date = date
        self.messageCount = messageCount
        self.threadCount = threadCount
        self.immediateCount = immediateCount
        self.flaggedCount = flaggedCount
        self.actionCount = actionCount
    }
}

public enum MailReview {
    /// Apparie **toutes** les conversations de l'extraction au jugement de l'IA : les classées
    /// gardent leur bucket, les autres sortent avec `bucket == nil` (elles forment la section
    /// « peut être archivé »). Un `id` hors limites du triage est ignoré.
    public static func entries(
        result: MailFetchResult,
        triage: MailTriage,
        date: String,
        actionIDs: [Int: UUID] = [:]
    ) -> [MailReviewEntry] {
        var judged: [Int: MailTriageItem] = [:]
        for item in triage.items where (1...result.threads.count).contains(item.id) {
            judged[item.id] = item                                   // doublon : dernière occurrence, comme au rendu
        }
        return result.threads.enumerated().map { offset, thread in
            let index = offset + 1
            let item = judged[index]
            return MailReviewEntry(
                reviewDate: date,
                index: index,
                subject: thread.subject,
                sender: MailReport.senderName(thread.last.sender),
                url: thread.last.url,
                messageCount: thread.messages.count,
                unread: thread.messages.filter { !$0.isRead }.count,
                flagged: thread.flagged,
                bucket: item?.bucket,
                importance: item?.importance ?? "",
                action: item?.action ?? "",
                deadline: item?.deadline ?? "",
                why: item?.why ?? "",
                summary: item?.summary ?? "",
                actionID: actionIDs[index])
        }
    }

    /// Section ⚪ : les conversations non classées, regroupées par expéditeur (plus nombreux
    /// d'abord). On ne liste jamais 40 newsletters une par une. `isArchived` permet d'y verser
    /// aussi les conversations traitées (action terminée ou abandonnée), que l'UI connaît seule.
    public static func archiveGroups(
        _ entries: [MailReviewEntry],
        isArchived: (MailReviewEntry) -> Bool = { $0.bucket == nil }
    ) -> [(sender: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in entries where isArchived(e) { counts[e.sender, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (sender: $0.key, count: $0.value) }
    }
}
