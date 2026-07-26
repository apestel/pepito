import Foundation
import EventKit
import ActionKit

/// Export des plans d'action vers des outils externes — aucune dépendance ajoutée : EventKit
/// (Rappels) et URL scheme (Things). Les actions sortent ainsi du Vault vers là où l'utilisateur
/// travaille (Phase E).
public enum ActionExport {
    /// URL scheme Things 3 (`things:///add`) — repli si l'utilisateur préfère Things aux Rappels.
    /// Pure et testable ; l'app l'ouvre via `NSWorkspace`.
    public static func thingsURL(title: String, notes: String = "") -> URL? {
        var c = URLComponents()
        c.scheme = "things"
        c.host = ""
        c.path = "/add"
        c.queryItems = [URLQueryItem(name: "title", value: title)]
        if !notes.isEmpty { c.queryItems?.append(URLQueryItem(name: "notes", value: notes)) }
        return c.url
    }
}

/// Crée un rappel par action dans Rappels (Apple). @MainActor car EKEventStore n'est pas Sendable.
@MainActor
public final class RemindersExporter {
    private let store = EKEventStore()

    public init() {}

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToReminders()) ?? false
    }

    /// Crée un rappel par action ; retourne le nombre créé. Dégrade à 0 si l'accès est refusé.
    public func export(_ items: [ActionItem]) async -> Int {
        guard await requestAccess(), let calendar = store.defaultCalendarForNewReminders() else { return 0 }
        var created = 0
        for a in items {
            let reminder = EKReminder(eventStore: store)
            reminder.title = a.owner.map { "\(a.title) (@\($0))" } ?? a.title
            reminder.calendar = calendar
            if let due = a.dueDate {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
            }
            do { try store.save(reminder, commit: false); created += 1 } catch { continue }
        }
        try? store.commit()
        return created
    }
}
