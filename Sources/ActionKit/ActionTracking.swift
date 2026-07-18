import Foundation

/// Aides au suivi des plans d'action (relances, échéances, tri) — cœur de la Phase 7.
public enum ActionTracking {
    /// Actions encore ouvertes (todo / in-progress / blocked).
    public static func openItems(in items: [ActionItem]) -> [ActionItem] {
        items.filter(\.isOpen)
    }

    /// Actions ouvertes dont l'échéance est dépassée.
    public static func overdueItems(asOf now: Date, in items: [ActionItem]) -> [ActionItem] {
        items.filter { item in
            guard item.isOpen, let due = item.dueDate else { return false }
            return due < now
        }
    }

    /// Actions ouvertes à échéance dans les `days` prochains jours (relances à venir).
    public static func upcomingItems(
        within days: Int,
        asOf now: Date,
        in items: [ActionItem],
        calendar: Calendar = .current
    ) -> [ActionItem] {
        guard let horizon = calendar.date(byAdding: .day, value: days, to: now) else { return [] }
        return items.filter { item in
            guard item.isOpen, let due = item.dueDate else { return false }
            return due >= now && due <= horizon
        }
    }

    /// Tri de suivi : priorité décroissante, puis échéance la plus proche, puis titre.
    public static func sortedForFollowUp(_ items: [ActionItem]) -> [ActionItem] {
        items.sorted { lhs, rhs in
            if lhs.priority.rawValue != rhs.priority.rawValue {
                return lhs.priority.rawValue > rhs.priority.rawValue
            }
            switch (lhs.dueDate, rhs.dueDate) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.title < rhs.title
            }
        }
    }

    /// Part d'avancement d'un ensemble (0…1) : proportion d'actions terminées (hors abandonnées).
    public static func completionRatio(in items: [ActionItem]) -> Double {
        let tracked = items.filter { $0.status != .dropped }
        guard !tracked.isEmpty else { return 0 }
        let done = tracked.filter { $0.status == .done }.count
        return Double(done) / Double(tracked.count)
    }
}
