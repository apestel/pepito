import Foundation
import Testing

@testable import AppCore

@Test func missionRecoveryMarksUncertainOperationsWithoutReplaying() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MissionStore(root: root)
    var m = Mission(title: "Prepare committee")
    m.state = "waiting"
    m.inFlightTool = "propose_action_status"
    m.inFlightCallID = "call-1"
    m.completedCalls = ["previous": "already applied"]
    try store.save(m)
    let loaded = try store.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].state == "interrupted")
    #expect(loaded[0].inFlightTool == nil)
    #expect(loaded[0].uncertainCalls == ["call-1"])
    #expect(loaded[0].completedCalls?["previous"] == "already applied")
    #expect(loaded[0].messages.last?.text.contains("incertain") == true)
    #expect(try store.load()[0].messages.count == 1)
}
@Test @MainActor func newMissionHasNoImplicitGlobalDataGrant() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = MissionCoordinator(root: root)
    coordinator.create()
    #expect(coordinator.selected?.includePepito == false)
    coordinator.setIncludePepito(true)
    #expect(try MissionStore(root: root).load()[0].includePepito == true)
}

@Test @MainActor func missionActionApplicationDetectsHumanEditsAndKeepsInvolvement() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db.sqlite"))
    let original = ActionItem(title: "Vérifier le budget", status: .todo, involvement: .follow)
    try db.saveActions([original])
    let app = MeetingCoordinator(
        settingsStore: SettingsStore(fileURL: root.appending(path: "settings.json")), database: db,
        tokenStore: InMemoryTokenStore(), recordingsRoot: root.appending(path: "recordings"),
        calendar: MockCalendar())
    try db.updateStatus(original.id, .blocked)
    #expect(throws: (any Error).self) { try app.missions.applyAction?(original, .done) }
    let edited = try #require(db.loadAllActions().first)
    #expect(edited.status == .blocked)
    try app.missions.applyAction?(edited, .done)
    let applied = try #require(db.loadAllActions().first)
    #expect(applied.status == .done)
    #expect(applied.involvement == .follow)
    #expect(try db.loadAllActions().count == 1)
}

@Test func missionToolDetailsSurviveRestartAndGroupAdjacentCalls() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var mission = Mission(title: "Dossier de travail")
    mission.scriptInternet = true
    mission.messages = [
        MissionMessage(role: "user", text: "Analyser"),
        MissionMessage(
            role: "tool", text: "run_script",
            tool: MissionToolCall(id: "a", name: "run_script", request: "{code:42}")),
        MissionMessage(
            role: "tool", text: "read_artifact",
            tool: MissionToolCall(id: "b", name: "read_artifact", request: "{}")),
        MissionMessage(role: "assistant", text: "Résultat"),
    ]
    mission.state = "running"
    mission.inFlightCallID = "a"
    let store = MissionStore(root: root)
    try store.save(mission)
    let loaded = try #require(store.load().first)
    #expect(loaded.scriptInternet == true)
    #expect(loaded.messageGroups[1].messages.count == 2)
    #expect(loaded.messages[1].tool?.state == "interrupted")
    #expect(loaded.messages[1].tool?.request == "{code:42}")
    // Older mission JSON has neither Internet grants nor structured tool details.
    var old = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(mission)) as? [String: Any])
    old.removeValue(forKey: "scriptInternet")
    old["messages"] = [
        ["id": UUID().uuidString, "role": "tool", "text": "Ancien résultat", "date": 0]
    ]
    let legacy = try JSONDecoder().decode(
        Mission.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(legacy.scriptInternet == nil)
    #expect(legacy.messages[0].tool == nil)
}

@Test @MainActor func missionHistoryManagementPersistsAndKeepsSelectionValid() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = MissionCoordinator(root: root)
    coordinator.create()
    let first = try #require(coordinator.selectedID)
    coordinator.create()
    let second = try #require(coordinator.selectedID)
    coordinator.rename(first, to: "  Comité  ")
    coordinator.rename(first, to: " \n ")
    coordinator.togglePin(first)
    #expect(coordinator.history.first?.id == first)
    let reloaded = MissionCoordinator(root: root)
    #expect(reloaded.history.first?.title == "Comité")
    #expect(reloaded.history.first?.hasCustomTitle == true)
    coordinator.setArchived(second, true)
    #expect(coordinator.selectedID == first)
    #expect(coordinator.history.count == 1)
    #expect(MissionCoordinator(root: root).archived.map(\.id) == [second])
    coordinator.setArchived(second, false)
    #expect(coordinator.history.count == 2)
    coordinator.delete(first)
    #expect(coordinator.selectedID == second)
    #expect(!FileManager.default.fileExists(atPath: coordinator.store.directory(first).path))
    #expect(MissionCoordinator(root: root).items.map(\.id) == [second])
    coordinator.delete(second)
    #expect(coordinator.selectedID == nil)
}

@Test func pendingSteeringSurvivesInterruptedMission() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MissionStore(root: root)
    var mission = Mission(title: "Steering")
    mission.state = "running"
    mission.pendingSteering = [MissionMessage(role: "user", text: "Concentre-toi sur le budget.")]
    try store.save(mission)
    let restored = try #require(store.load().first)
    #expect(restored.state == "interrupted")
    #expect(restored.pendingSteering?.first?.id == mission.pendingSteering?.first?.id)
    #expect(restored.pendingSteering?.first?.text == "Concentre-toi sur le budget.")
    #expect(restored.messages.allSatisfy { $0.role != "user" })
}

@Test func internetDefaultsAndConversationOverridesSurviveMigration() throws {
    let oldSettings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(oldSettings.missionInternetEnabled)
    var settings = oldSettings
    settings.missionInternetEnabled = false
    let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
    #expect(!restored.missionInternetEnabled)
    var mission = Mission(title: "Internet")
    #expect(mission.internetEnabled(default: true))
    #expect(!mission.internetEnabled(default: false))
    mission.scriptInternet = false
    let saved = try JSONDecoder().decode(Mission.self, from: JSONEncoder().encode(mission))
    #expect(!saved.internetEnabled(default: true))
    mission.scriptInternet = true
    #expect(mission.internetEnabled(default: false))
}

@Test @MainActor func internetPolicyRejectsDisabledConversations() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = MissionCoordinator(root: root)
    coordinator.create()
    let id = try #require(coordinator.selectedID)
    try coordinator.requireInternet(id)
    coordinator.setScriptInternet(false)
    #expect(throws: (any Error).self) { try coordinator.requireInternet(id) }
    coordinator.resetInternetOverride()
    try coordinator.requireInternet(id)
    coordinator.internetDefault = { false }
    #expect(throws: (any Error).self) { try coordinator.requireInternet(id) }
    coordinator.setScriptInternet(true)
    try coordinator.requireInternet(id)
}
