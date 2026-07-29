import Testing
import Foundation
@testable import ActionKit

@Test func moduleIdentity() {
    #expect(ActionKit.moduleName == "ActionKit")
}

@Test func openStatusesAreTracked() {
    #expect(ActionItem(title: "x", status: .todo).isOpen)
    #expect(ActionItem(title: "x", status: .inProgress).isOpen)
    #expect(ActionItem(title: "x", status: .blocked).isOpen)
    #expect(ActionItem(title: "x", status: .done).isOpen == false)
    #expect(ActionItem(title: "x", status: .dropped).isOpen == false)
}

// MARK: - Hierarchy

@Test func rootsAndChildren() {
    let a = ActionItem(title: "épique")
    let b = ActionItem(parentID: a.id, title: "sous-tâche 1")
    let c = ActionItem(parentID: a.id, title: "sous-tâche 2")
    let items = [a, b, c]
    #expect(ActionHierarchy.roots(in: items).map(\.id) == [a.id])
    #expect(Set(ActionHierarchy.children(of: a.id, in: items).map(\.id)) == [b.id, c.id])
}

@Test func descendantsAreTransitive() {
    let a = ActionItem(title: "a")
    let b = ActionItem(parentID: a.id, title: "b")
    let c = ActionItem(parentID: b.id, title: "c")
    let items = [a, b, c]
    #expect(Set(ActionHierarchy.descendants(of: a.id, in: items).map(\.id)) == [b.id, c.id])
    #expect(ActionHierarchy.depth(of: c.id, in: items) == 2)
}

@Test func orphanIsTreatedAsRoot() {
    let orphan = ActionItem(parentID: UUID(), title: "parent absent")
    #expect(ActionHierarchy.roots(in: [orphan]).count == 1)
}

@Test func cycleDetection() {
    let id1 = UUID(); let id2 = UUID()
    let a = ActionItem(id: id1, parentID: id2, title: "a")
    let b = ActionItem(id: id2, parentID: id1, title: "b")
    #expect(ActionHierarchy.hasCycle(in: [a, b]))
    // descendants et depth ne bouclent pas malgré le cycle
    #expect(ActionHierarchy.descendants(of: id1, in: [a, b]).count <= 2)
    #expect(ActionHierarchy.depth(of: id1, in: [a, b]) != nil)
}

// MARK: - Tracking

private func date(_ offsetDays: Int, from base: Date) -> Date {
    Calendar.current.date(byAdding: .day, value: offsetDays, to: base)!
}

@Test func overdueAndUpcoming() {
    let now = Date()
    let overdue = ActionItem(title: "en retard", dueDate: date(-1, from: now), status: .todo)
    let soon = ActionItem(title: "bientôt", dueDate: date(2, from: now), status: .inProgress)
    let far = ActionItem(title: "loin", dueDate: date(30, from: now), status: .todo)
    let doneOverdue = ActionItem(title: "fait", dueDate: date(-5, from: now), status: .done)
    let items = [overdue, soon, far, doneOverdue]

    #expect(ActionTracking.overdueItems(asOf: now, in: items).map(\.id) == [overdue.id])
    #expect(ActionTracking.upcomingItems(within: 7, asOf: now, in: items).map(\.id) == [soon.id])
    #expect(ActionTracking.openItems(in: items).count == 3)
}

@Test func followUpSortPrioritizes() {
    let now = Date()
    let low = ActionItem(title: "low", dueDate: date(1, from: now), status: .todo, priority: .low)
    let highNoDue = ActionItem(title: "high", status: .todo, priority: .high)
    let highSoon = ActionItem(title: "high soon", dueDate: date(1, from: now), status: .todo, priority: .high)
    let sorted = ActionTracking.sortedForFollowUp([low, highNoDue, highSoon])
    // Haute priorité d'abord, échéance proche avant sans échéance
    #expect(sorted.first?.id == highSoon.id)
    #expect(sorted.last?.id == low.id)
}

@Test func completionRatioIgnoresDropped() {
    let items = [
        ActionItem(title: "1", status: .done),
        ActionItem(title: "2", status: .todo),
        ActionItem(title: "3", status: .dropped),
    ]
    // 1 done sur 2 suivies (abandonnée exclue)
    #expect(ActionTracking.completionRatio(in: items) == 0.5)
}

// MARK: - Implication (qui porte, qui suit)

@Test func involvementIsDerivedFromOwner() {
    let me = "Antoine Pestel"
    let team = ["Marc Dupont", "Sofia"]
    func involvement(owner: String?) -> Involvement {
        ActionItem(title: "x", owner: owner).resolvedInvolvement(me: me, team: team)
    }

    #expect(involvement(owner: "Antoine Pestel") == .own)
    #expect(involvement(owner: "antoine pestel") == .own)     // casse
    #expect(involvement(owner: "Antoine") == .own)            // prénom seul
    #expect(involvement(owner: "Marc Dupont") == .follow)
    #expect(involvement(owner: "Sofia") == .follow)
    #expect(involvement(owner: "Sofía") == .follow)           // accent
    #expect(involvement(owner: "Claire Martin") == .info)
    // Sans responsable, l'action retombe sur moi plutôt que de disparaître dans « pour info ».
    #expect(involvement(owner: nil) == .own)
    #expect(involvement(owner: "  ") == .own)
}

@Test func manualInvolvementOverridesDerivation() {
    let watched = ActionItem(title: "x", owner: "Claire Martin", involvement: .follow)
    #expect(watched.resolvedInvolvement(me: "Antoine", team: []) == .follow)
    let ignored = ActionItem(title: "x", owner: "Antoine", involvement: .info)
    #expect(ignored.resolvedInvolvement(me: "Antoine", team: []) == .info)
}

@Test func samePersonDoesNotMergeDistinctFullNames() {
    // Deux collaborateurs partageant un prénom restent deux personnes.
    #expect(ActionItem.samePerson("Marc Dupont", "Marc Durand") == false)
    #expect(ActionItem.samePerson("Marc", "Marc Durand"))
    #expect(ActionItem.samePerson("", "Marc") == false)
}

// MARK: - Projets

@Test func projectMatchKeyIgnoresCaseAccentsAndPunctuation() {
    #expect(Project.matchKey("Migration SI") == Project.matchKey("migration  si"))
    #expect(Project.matchKey("Réunion : Été 2026") == "reunion ete 2026")
    #expect(Project.matchKey("") == "")
}

@Test func projectGroupNamesOrphans() {
    let p = Project(name: "Migration SI")
    #expect(ProjectGroup(project: p, actions: []).name == "Migration SI")
    #expect(ProjectGroup(project: nil, actions: []).name == "Sans projet")
    #expect(ProjectGroup(project: nil, actions: []).id == "sans-projet")
}

// MARK: - Aplatissement pour l'affichage

@Test func flattenedRendersChildrenUnderTheirParent() {
    let a = ActionItem(title: "épique")
    let a1 = ActionItem(parentID: a.id, title: "sous-tâche")
    let a11 = ActionItem(parentID: a1.id, title: "sous-sous-tâche")
    let b = ActionItem(title: "autre racine")
    // Les racines gardent leur ordre d'entrée (celui de la base) ; les enfants remontent sous leur
    // parent quelle que soit leur position.
    let flat = ActionHierarchy.flattened(in: [a, b, a11, a1])

    #expect(flat.map(\.item.title) == ["épique", "sous-tâche", "sous-sous-tâche", "autre racine"])
    #expect(flat.map(\.depth) == [0, 1, 2, 0])
}

@Test func flattenedEmitsEveryActionEvenInACycle() {
    // Un cycle n'a pas de racine : sans rattrapage, ses actions disparaîtraient de l'affichage.
    let x = UUID(), y = UUID()
    let items = [
        ActionItem(id: x, parentID: y, title: "x"),
        ActionItem(id: y, parentID: x, title: "y"),
    ]
    #expect(ActionHierarchy.hasCycle(in: items))
    #expect(Set(ActionHierarchy.flattened(in: items).map(\.item.title)) == ["x", "y"])
}
