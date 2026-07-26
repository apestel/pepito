import Foundation

/// Urgence d'une conversation. `week` sert aussi de repli quand l'IA renvoie une valeur inconnue :
/// mieux vaut un item mal rangé qu'un item disparu du rapport ET de l'archive.
public enum MailBucket: String, Sendable, Codable, CaseIterable {
    case immediate, week, info

    public var title: String {
        switch self {
        case .immediate: "🔴 Action immédiate"
        case .week: "🟠 Cette semaine"
        case .info: "🟢 Information"
        }
    }
}

/// Jugement porté sur **une** conversation. `id` est l'index `#N` du digest (clé de jointure).
/// Décodage tolérant : un champ absent vaut "", un `bucket` inconnu devient `.week`, un `id`
/// manquant devient `-1` (l'item est alors ignoré au rendu plutôt que de faire échouer tout le lot).
public struct MailTriageItem: Sendable, Equatable, Decodable {
    public let id: Int
    public let bucket: MailBucket
    /// `Critique` / `Haute` / `Normale` / `Faible`.
    public let importance: String
    /// `Répondre` / `Décider` / `Lire` / `Archiver` / `Suivre` / `Aucune`.
    public let action: String
    /// Échéance ISO `AAAA-MM-JJ`, ou "" si aucune date concrète.
    public let deadline: String
    public let why: String
    public let summary: String
    /// Libellé impératif pour la todo ; vide → généré depuis `action` + sujet.
    public let todo: String

    public init(
        id: Int, bucket: MailBucket, importance: String = "", action: String = "",
        deadline: String = "", why: String = "", summary: String = "", todo: String = ""
    ) {
        self.id = id
        self.bucket = bucket
        self.importance = importance
        self.action = action
        self.deadline = deadline
        self.why = why
        self.summary = summary
        self.todo = todo
    }

    enum CodingKeys: String, CodingKey {
        case id, bucket, importance, action, deadline, why, summary, todo
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? -1
        bucket = MailBucket(rawValue: try c.decodeIfPresent(String.self, forKey: .bucket) ?? "") ?? .week
        importance = try c.decodeIfPresent(String.self, forKey: .importance) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        deadline = try c.decodeIfPresent(String.self, forKey: .deadline) ?? ""
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        todo = try c.decodeIfPresent(String.self, forKey: .todo) ?? ""
    }
}

/// Réponse de triage complète. Les conversations absentes d'`items` sont archivées (⚪).
public struct MailTriage: Sendable, Equatable, Decodable {
    public let period: String
    public let date: String
    public let items: [MailTriageItem]

    public init(period: String = "", date: String = "", items: [MailTriageItem]) {
        self.period = period
        self.date = date
        self.items = items
    }

    enum CodingKeys: String, CodingKey { case period, date, items }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decodeIfPresent(String.self, forKey: .period) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        items = try c.decodeIfPresent([MailTriageItem].self, forKey: .items) ?? []
    }
}
