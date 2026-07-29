import Foundation

/// Plans d'action : hiérarchie, statuts, échéances, suivi. Implémentation Phase 7 (PLAN.md).
public enum ActionKit {
    public static let moduleName = "ActionKit"
}

/// Statut de suivi d'un plan d'action.
public enum ActionStatus: String, Sendable, CaseIterable, Codable {
    case todo
    case inProgress = "in-progress"
    case blocked
    case done
    case dropped
}

/// Priorité relative.
public enum ActionPriority: Int, Sendable, CaseIterable, Codable {
    case low = 0
    case medium = 1
    case high = 2
}

/// Degré d'implication personnelle dans une action — l'axe de tri du suivi.
public enum Involvement: String, Sendable, CaseIterable, Codable {
    /// Je la porte.
    case own
    /// À relancer : confiée à mon équipe, ou marquée importante à la main.
    case follow
    /// Ni l'un ni l'autre : elle existe, je n'ai rien à en faire.
    case info

    public var label: String {
        switch self {
        case .own: "À moi"
        case .follow: "À suivre"
        case .info: "Pour info"
        }
    }
}

/// Plan d'action hiérarchisable (`parentID`), rattaché à une réunion d'origine.
public struct ActionItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var parentID: UUID?
    public var meetingID: UUID?
    /// Projet de rattachement. `nil` = non classée (une même réunion en produit sur plusieurs).
    public var projectID: UUID?
    public var title: String
    public var details: String
    public var owner: String?
    public var dueDate: Date?
    public var status: ActionStatus
    public var priority: ActionPriority
    /// Surcharge manuelle de l'implication. `nil` = déduite du responsable
    /// (`resolvedInvolvement(me:team:)`), ce qui laisse l'historique se reclasser tout seul quand la
    /// liste de l'équipe change.
    public var involvement: Involvement?
    /// Origine externe ouvrable (ex. `message://…` pour une action issue d'un mail). `nil` pour les
    /// actions de réunion, dont l'origine est `meetingID`.
    public var sourceURL: String?

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        meetingID: UUID? = nil,
        projectID: UUID? = nil,
        title: String,
        details: String = "",
        owner: String? = nil,
        dueDate: Date? = nil,
        status: ActionStatus = .todo,
        priority: ActionPriority = .medium,
        involvement: Involvement? = nil,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.meetingID = meetingID
        self.projectID = projectID
        self.title = title
        self.details = details
        self.owner = owner
        self.dueDate = dueDate
        self.status = status
        self.priority = priority
        self.involvement = involvement
        self.sourceURL = sourceURL
    }

    /// Une action est « ouverte » si elle reste à traiter (pour le suivi/relances).
    public var isOpen: Bool {
        status == .todo || status == .inProgress || status == .blocked
    }

    /// Implication explicite si elle a été posée à la main, sinon déduite du responsable.
    /// Sans responsable, l'action retombe sur moi : c'est le défaut le moins risqué (une action
    /// orpheline qu'on oublie coûte plus cher qu'une action classée à tort « à moi »).
    public func resolvedInvolvement(me: String, team: [String]) -> Involvement {
        if let involvement { return involvement }
        guard let owner, !owner.trimmingCharacters(in: .whitespaces).isEmpty else { return .own }
        if Self.samePerson(owner, me) { return .own }
        if team.contains(where: { Self.samePerson(owner, $0) }) { return .follow }
        return .info
    }

    /// Rapprochement de deux noms : égalité insensible à la casse et aux accents, ou égalité du
    /// premier prénom (« Marc » ≡ « Marc Dupont »).
    /// ponytail: rapprochement par nom, pas d'identité ; table de personnes si ça dérape.
    public static func samePerson(_ a: String, _ b: String) -> Bool {
        let x = normalizeName(a), y = normalizeName(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard let fx = x.split(separator: " ").first, let fy = y.split(separator: " ").first else {
            return false
        }
        // Un prénom seul ne matche que s'il est le prénom de l'autre — deux noms complets distincts
        // partageant un prénom restent deux personnes.
        return fx == fy && (x == fx || y == fy)
    }

    private static func normalizeName(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
