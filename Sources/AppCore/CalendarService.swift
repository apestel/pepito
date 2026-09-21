import Foundation
import EventKit

/// Événement de calendrier réduit à ce dont Pépito a besoin : pré-remplir la réunion (titre,
/// participants) et donner du contexte à l'IA (agenda). Aucune donnée ne quitte la machine.
public struct CalEvent: Sendable, Equatable {
    public let title: String
    public let participants: [String]
    public let agenda: String
    public let start: Date
    public let end: Date

    public init(title: String, participants: [String], agenda: String, start: Date, end: Date) {
        self.title = title
        self.participants = participants
        self.agenda = agenda
        self.start = start
        self.end = end
    }
}

/// Seam injectable (comme `AudioCapturing`, @MainActor) : fournit l'événement en cours pour tester
/// sans EventKit. Non-Sendable car EventKit (`EKEventStore`) ne l'est pas — utilisé depuis le seul
/// @MainActor du coordinateur.
@MainActor
public protocol CalendarProviding: AnyObject {
    func requestAccess() async -> Bool
    func currentOrImminentEvent(now: Date) async -> CalEvent?
}

public extension CalendarProviding {
    func currentOrImminentEvent() async -> CalEvent? { await currentOrImminentEvent(now: Date()) }
}

/// Implémentation EventKit. Cherche l'événement couvrant `now` (réunion en cours), sinon le prochain
/// à démarrer dans les 15 min. Nécessite l'accès Calendriers (TCC) — dégrade en `nil` sinon.
@MainActor
public final class EventKitCalendar: CalendarProviding {
    private let store = EKEventStore()

    public init() {}

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func currentOrImminentEvent(now: Date) async -> CalEvent? {
        // Déclenche la demande d'accès (TCC) au premier usage ; si refusé/indéterminé, dégrade en nil.
        if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            guard await requestAccess() else { return nil }
        }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-4 * 3600),
            end: now.addingTimeInterval(15 * 60),
            calendars: nil)
        let events = store.events(matching: predicate).filter { !$0.isAllDay && $0.endDate > now }
        // En cours (a déjà démarré) prioritaire ; sinon le prochain à commencer.
        let ongoing = events.filter { $0.startDate <= now }.max { $0.startDate < $1.startDate }
        let upcoming = events.filter { $0.startDate > now }.min { $0.startDate < $1.startDate }
        return (ongoing ?? upcoming).map(Self.map)
    }

    static func map(_ e: EKEvent) -> CalEvent {
        var names = (e.attendees ?? []).compactMap { $0.name }
        if let organizer = e.organizer?.name, !names.contains(organizer) { names.insert(organizer, at: 0) }
        return CalEvent(
            title: e.title ?? "",
            participants: names,
            agenda: e.notes ?? "",
            start: e.startDate,
            end: e.endDate)
    }
}

extension EventKitCalendar {
    /// Lecture bornée pour les missions ; aucune création d'événement.
    public func eventsText(start: String, end: String) async throws -> String {
        let f=ISO8601DateFormatter()
        guard let a=f.date(from:start), let b=f.date(from:end), b>a, b.timeIntervalSince(a)<=31*86400 else {
            throw NSError(domain:"Calendar",code:1,userInfo:[NSLocalizedDescriptionKey:"Période ISO8601 invalide (maximum 31 jours)."])
        }
        guard await requestAccess() else { throw NSError(domain:"Calendar",code:2,userInfo:[NSLocalizedDescriptionKey:"Accès au calendrier refusé."]) }
        return store.events(matching:store.predicateForEvents(withStart:a,end:b,calendars:nil)).prefix(100).map {
            "\($0.startDate.description) — \($0.title ?? "")\n\(($0.notes ?? "").prefix(1000))"
        }.joined(separator:"\n\n")
    }
}
