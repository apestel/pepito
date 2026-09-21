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
