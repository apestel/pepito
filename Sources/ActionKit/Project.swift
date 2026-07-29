import Foundation

/// Un projet clos disparaît des sélecteurs et du filtre de suivi, mais ses actions restent visibles.
public enum ProjectStatus: String, Sendable, CaseIterable, Codable {
    case active
    case closed

    public var label: String {
        switch self {
        case .active: "Actif"
        case .closed: "Clos"
        }
    }
}

/// Regroupement transverse des actions : une même réunion produit souvent des actions de plusieurs
/// projets. Identifié par `id` et non par son nom, précisément pour rester renommable.
public struct Project: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var status: ProjectStatus
    /// Nom de couleur SwiftUI (« blue », « orange »…) — pastille dans le suivi. `nil` = gris.
    public var color: String?
    /// Référent du projet (texte libre, même convention que `ActionItem.owner`).
    public var owner: String?

    public init(
        id: UUID = UUID(),
        name: String,
        status: ProjectStatus = .active,
        color: String? = nil,
        owner: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.color = color
        self.owner = owner
    }

    /// Clé de rapprochement d'un nom de projet (titre d'événement calendrier, sortie de l'IA) :
    /// minuscules, sans accents ni ponctuation.
    public static func matchKey(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Actions d'un même projet, pour l'affichage groupé du suivi. `project == nil` = non classées.
public struct ProjectGroup: Sendable, Identifiable, Equatable {
    public let project: Project?
    public let actions: [ActionItem]

    public init(project: Project?, actions: [ActionItem]) {
        self.project = project
        self.actions = actions
    }

    public var id: String { project?.id.uuidString ?? "sans-projet" }
    public var name: String { project?.name ?? "Sans projet" }
}
