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

/// Plan d'action hiérarchisable (`parentID`), rattaché à une réunion d'origine.
public struct ActionItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var parentID: UUID?
    public var meetingID: UUID?
    public var title: String
    public var details: String
    public var owner: String?
    public var dueDate: Date?
    public var status: ActionStatus
    public var priority: ActionPriority
    /// Origine externe ouvrable (ex. `message://…` pour une action issue d'un mail). `nil` pour les
    /// actions de réunion, dont l'origine est `meetingID`.
    public var sourceURL: String?

    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        meetingID: UUID? = nil,
        title: String,
        details: String = "",
        owner: String? = nil,
        dueDate: Date? = nil,
        status: ActionStatus = .todo,
        priority: ActionPriority = .medium,
        sourceURL: String? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.meetingID = meetingID
        self.title = title
        self.details = details
        self.owner = owner
        self.dueDate = dueDate
        self.status = status
        self.priority = priority
        self.sourceURL = sourceURL
    }

    /// Une action est « ouverte » si elle reste à traiter (pour le suivi/relances).
    public var isOpen: Bool {
        status == .todo || status == .inProgress || status == .blocked
    }
}
