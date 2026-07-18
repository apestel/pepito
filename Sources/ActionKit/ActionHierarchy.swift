import Foundation

/// Opérations de hiérarchisation sur un ensemble plat de plans d'action (`parentID`).
public enum ActionHierarchy {
    /// Actions racines (sans parent, ou dont le parent est absent de l'ensemble).
    public static func roots(in items: [ActionItem]) -> [ActionItem] {
        let ids = Set(items.map(\.id))
        return items.filter { $0.parentID == nil || !ids.contains($0.parentID!) }
    }

    /// Enfants directs d'une action.
    public static func children(of parentID: UUID, in items: [ActionItem]) -> [ActionItem] {
        items.filter { $0.parentID == parentID }
    }

    /// Descendants (transitifs) d'une action. Robuste aux cycles.
    public static func descendants(of id: UUID, in items: [ActionItem]) -> [ActionItem] {
        var result: [ActionItem] = []
        var visited: Set<UUID> = [id]
        var queue = children(of: id, in: items)
        while let next = queue.first {
            queue.removeFirst()
            guard visited.insert(next.id).inserted else { continue }
            result.append(next)
            queue.append(contentsOf: children(of: next.id, in: items))
        }
        return result
    }

    /// Profondeur d'une action (racine = 0). Retourne `nil` si l'`id` est introuvable.
    public static func depth(of id: UUID, in items: [ActionItem]) -> Int? {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        guard var current = byID[id] else { return nil }
        var depth = 0
        var visited: Set<UUID> = [current.id]
        while let parentID = current.parentID, let parent = byID[parentID] {
            guard visited.insert(parentID).inserted else { break } // cycle
            depth += 1
            current = parent
        }
        return depth
    }

    /// Détecte un cycle parent→enfant dans l'ensemble.
    public static func hasCycle(in items: [ActionItem]) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in items {
            var visited: Set<UUID> = []
            var current: ActionItem? = item
            while let node = current {
                guard visited.insert(node.id).inserted else { return true }
                current = node.parentID.flatMap { byID[$0] }
            }
        }
        return false
    }
}
