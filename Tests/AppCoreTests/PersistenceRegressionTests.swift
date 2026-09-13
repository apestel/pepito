import Testing
import Foundation
import SQLite3
import AIKit
import VaultKit
@testable import AppCore

private let analysisJSON = #"{"summary":"Résumé","actions":[{"title":"Préparer le budget","children":[{"title":"Chiffrer"}]}]}"#

/// Connexion indépendante pour provoquer des échecs SQLite réels, sans modifier le code de production.
private func fixtureSQL(_ sql: String, at path: URL) throws {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    try #require(sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    try #require(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
}

@MainActor
private func storageCoordinator(root: URL, database: Database, provider: any AIProvider) -> MeetingCoordinator {
    let app = MeetingCoordinator(
        settingsStore: SettingsStore(fileURL: root.appending(path: "settings.json")),
        database: database,
        tokenStore: InMemoryTokenStore(),
        capture: MockCapturer(),
        calendar: MockCalendar(),
        providerFactory: { _, _ in provider })
    app.settings.vaultPath = root.appending(path: "vault").path
    return app
}

@MainActor
@Test func sameDayMeetingsHaveIndependentDocumentsAndKeepTheirPaths() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-folders-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    let app = storageCoordinator(root: root, database: db, provider: PipelineScriptedProvider(Array(repeating: analysisJSON, count: 3)))
    let first = Meeting(title: "Point projet", status: .awaitingName, transcript: "Premier transcript")
    let second = Meeting(title: first.title, startedAt: first.startedAt, status: .awaitingName, transcript: "Second transcript")
    for meeting in [first, second] {
        try db.save(meeting)
        app.setPending(meeting)
        await app.nameAndProcess(title: meeting.title, tags: [])
        #expect(app.processingPhase == .done)
    }
    let meetings = try db.loadAll()
    let a = try #require(meetings.first { $0.id == first.id })
    let b = try #require(meetings.first { $0.id == second.id })
    #expect(a.folderPath != b.folderPath)
    let vault = Vault(root: URL(fileURLWithPath: app.settings.vaultPath))
    #expect(try vault.read(relativePath: PathBuilder.transcriptPath(meetingFolder: a.folderPath)).markdown == first.transcript)
    #expect(try vault.read(relativePath: PathBuilder.transcriptPath(meetingFolder: b.folderPath)).markdown == second.transcript)
    app.setPending(a)
    await app.nameAndProcess(title: "Titre corrigé", tags: [])
    #expect(app.pendingMeeting?.folderPath == a.folderPath)
    app.deleteMeeting(try #require(app.pendingMeeting))
    #expect(vault.exists(relativePath: PathBuilder.summaryPath(meetingFolder: b.folderPath)))
    #expect(try db.loadAll().map(\.id) == [b.id])
}

@MainActor
@Test func existingSharedFolderIsKeptWhenOneLegacyMeetingIsDeleted() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-legacy-path-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    let first = Meeting(title: "Ancienne", status: .processing, folderPath: "2026/09/13-ancienne", transcript: "t")
    let second = Meeting(title: first.title, status: .done, folderPath: first.folderPath)
    try db.save(first)
    try db.save(second)
    let app = storageCoordinator(root: root, database: db, provider: PipelineScriptedProvider([analysisJSON]))
    app.setPending(first)
    await app.nameAndProcess(title: "Titre modifié", tags: [])
    #expect(app.pendingMeeting?.folderPath == first.folderPath)
    app.deleteMeeting(try #require(app.pendingMeeting))
    #expect(Vault(root: URL(fileURLWithPath: app.settings.vaultPath)).exists(
        relativePath: PathBuilder.summaryPath(meetingFolder: second.folderPath)))
}

@MainActor
@Test(arguments: ["transcript.md", "summary.md", "action-plan.md"])
func vaultWriteFailureKeepsMeetingRetryable(file: String) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-write-failure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    let meeting = Meeting(title: "Sync", status: .awaitingName, folderPath: "legacy", transcript: "Transcript conservé")
    try db.save(meeting)
    let app = storageCoordinator(root: root, database: db, provider: PipelineScriptedProvider([analysisJSON, analysisJSON]))
    let blocked = root.appending(path: "vault/legacy/\(file)")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
    app.setPending(meeting)
    await app.nameAndProcess(title: "Sync", tags: [])
    #expect(app.processingPhase?.isFailed == true)
    #expect(app.isProcessing == false)
    let saved = try #require(db.loadAll().first)
    #expect(saved.status.isResumable)
    #expect(saved.lastError != nil)
    #expect(saved.transcript == meeting.transcript)
    #expect(try db.loadAllActions().isEmpty)
    try FileManager.default.removeItem(at: blocked)
    await app.retryProcessing()
    #expect(app.processingPhase == .done)
    #expect(try db.loadAll().first?.lastError == nil)
    #expect(try db.loadAllActions().count == 2)
}

@Test func databaseOpeningAndReadingErrorsAreThrown() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-db-errors-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "file")
    try Data("not a directory".utf8).write(to: file)
    let inaccessible = Database(path: file.appending(path: "db"))
    #expect(throws: (any Error).self) { try inaccessible.loadAll() }
    #expect(throws: (any Error).self) { try inaccessible.save(Meeting(title: "X")) }
    let db = Database(path: root.appending(path: "db"))
    try fixtureSQL("DROP TABLE action", at: db.path)
    #expect(throws: DatabaseError.self) { try db.loadAllActions() }
}

@Test func failedMeetingTagWriteRollsBackTheWholeSave() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-tag-rollback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    var meeting = Meeting(title: "Original", tags: ["ancien"])
    try db.save(meeting)
    try fixtureSQL("""
        CREATE TRIGGER fail_tag BEFORE INSERT ON meeting_tag WHEN NEW.tag_name='reject'
        BEGIN SELECT RAISE(ABORT, 'test failure'); END;
        """, at: db.path)
    meeting.title = "Modification"
    meeting.tags = ["reject"]
    #expect(throws: DatabaseError.self) { try db.save(meeting) }
    #expect(try db.loadAll().first?.title == "Original")
    #expect(try db.loadAll().first?.tags == ["ancien"])
    #expect(try db.allTags() == ["ancien"])
}

@Test func failedActionBatchAndMailReplacementAreRolledBack() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-batch-rollback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    let good = ActionItem(title: "Valide")
    let bad = ActionItem(meetingID: UUID(), title: "Réunion inexistante")
    #expect(throws: DatabaseError.self) { try db.saveActions([good, bad]) }
    #expect(try db.loadAllActions().isEmpty)
    let entry = MailReviewEntry(reviewDate: "2026-09-13", index: 1, subject: "Original", sender: "s",
        url: "message://test", messageCount: 1, unread: 0, flagged: false, bucket: nil,
        importance: "", action: "", deadline: "", why: "", summary: "", actionID: nil)
    try db.saveMailReview([entry])
    #expect(throws: DatabaseError.self) {
        try db.transaction {
            try db.saveActions([good])
            // Duplicate primary key after DELETE : the old review and the action batch must roll back.
            try db.saveMailReview([entry, entry])
        }
    }
    #expect(try db.loadAllActions().isEmpty)
    #expect(try db.mailReview(date: entry.reviewDate) == [entry])
}

@MainActor
@Test func failedManualEditDoesNotChangeMemoryOrPartiallyPersist() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-edit-rollback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    let original = ActionItem(title: "Original")
    try db.saveActions([original])
    let app = storageCoordinator(root: root, database: db, provider: PipelineScriptedProvider([]))
    try fixtureSQL("""
        CREATE TRIGGER fail_status BEFORE UPDATE OF status ON action
        BEGIN SELECT RAISE(ABORT, 'test failure'); END;
        """, at: db.path)
    var edit = original
    edit.title = "Modifié"
    edit.involvement = .follow
    edit.status = .done
    app.updateAction(edit)
    #expect(app.storageError != nil)
    #expect(app.actions == [original])
    #expect(try db.loadAllActions() == [original])
}

@MainActor
@Test func failedFinalSaveLeavesNoPartialActionsAndCanRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-final-rollback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    let meeting = Meeting(title: "Sync", status: .awaitingName, transcript: "t")
    try db.save(meeting)
    let app = storageCoordinator(root: root, database: db, provider: PipelineScriptedProvider([analysisJSON, analysisJSON]))
    try fixtureSQL("""
        CREATE TRIGGER fail_done BEFORE UPDATE ON meeting WHEN NEW.status='done'
        BEGIN SELECT RAISE(ABORT, 'test failure'); END;
        """, at: db.path)
    app.setPending(meeting)
    await app.nameAndProcess(title: "Sync", tags: [])
    #expect(app.processingPhase?.isFailed == true)
    #expect(app.actions.isEmpty)
    #expect(try db.loadAllActions().isEmpty)
    #expect(try db.loadAll().first?.status == .processing)
    let vault = Vault(root: URL(fileURLWithPath: app.settings.vaultPath))
    let planPath = PathBuilder.actionPlanPath(meetingFolder: try #require(app.pendingMeeting).folderPath)
    let planBeforeRetry = try vault.read(relativePath: planPath).markdown
    try fixtureSQL("DROP TRIGGER fail_done", at: db.path)
    await app.retryProcessing()
    #expect(app.processingPhase == .done)
    #expect(app.actions.count == 2)
    #expect(try db.loadAllActions().count == 2)
    #expect(try vault.read(relativePath: planPath).markdown == planBeforeRetry)
}

@MainActor
@Test func reprocessingPreservesActionsAcrossReloadAndManualTitleChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-idempotence-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    let meeting = Meeting(title: "Sync", status: .awaitingName, transcript: "t")
    try db.save(meeting)
    let app = storageCoordinator(root: root, database: db, provider: PipelineScriptedProvider([analysisJSON, analysisJSON, "{}"] ))
    app.setPending(meeting)
    await app.nameAndProcess(title: "Sync", tags: [])
    let parent = try #require(app.actions.first { $0.parentID == nil })
    var child = try #require(app.actions.first { $0.parentID == parent.id })
    child.title = "Titre corrigé par l'humain"
    child.owner = "Alice"
    child.status = .done
    child.involvement = .follow
    app.updateAction(child)
    let manual = ActionItem(meetingID: meeting.id, title: "Ajout manuel", status: .blocked)
    app.addAction(manual)
    await app.retryProcessing()
    #expect(app.processingPhase == .done)
    #expect(app.actions.count == 3)
    #expect(app.actions.first { $0.id == child.id } == child)
    #expect(app.actions.contains(manual))
    #expect(try Database(path: db.path).loadAllActions() == app.actions)
    // A model omission must not hide the saved actions or leave a stale generated plan.
    await app.retryProcessing()
    #expect(app.actions.count == 3)
    let plan = try Vault(root: URL(fileURLWithPath: app.settings.vaultPath)).read(
        relativePath: PathBuilder.actionPlanPath(meetingFolder: try #require(app.pendingMeeting).folderPath))
    #expect(plan.markdown.contains(child.title))
    #expect(plan.markdown.contains(manual.title))
}

@Test func legacyActionMatchingIsConservativeAndUsesExplicitIDs() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-match-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let meeting = Meeting(title: "Sync", folderPath: "legacy")
    let old = ActionItem(meetingID: meeting.id, title: "Ancienne tâche", status: .done, involvement: .follow)
    let exact = #"{"actions":[{"title":"ancienne   tâche"}]}"#
    let explicit = "{\"actions\":[{\"id\":\"\(old.id)\",\"title\":\"Reformulation\"}]}"
    let invalid = "{\"actions\":[{\"id\":\"\(UUID())\",\"title\":\"Reformulation\"}]}"
    let provider = PipelineScriptedProvider([exact, explicit, exact, invalid])
    let pipeline = MeetingPipeline(provider: provider, vault: Vault(root: root))
    for _ in 0..<2 {
        let result = try await pipeline.process(meeting: meeting, transcript: "t", existingActions: [old])
        #expect(result.actions == [old])
    }
    let duplicate = ActionItem(meetingID: meeting.id, title: old.title)
    await #expect(throws: (any Error).self) {
        try await pipeline.process(meeting: meeting, transcript: "t", existingActions: [old, duplicate])
    }
    await #expect(throws: (any Error).self) {
        try await pipeline.process(meeting: meeting, transcript: "t", existingActions: [old])
    }
}

@MainActor
@Test func reprocessingCannotResetItsOwnManualStatusViaActionUpdates() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-status-guard-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    let meeting = Meeting(title: "Sync", status: .processing, transcript: "t")
    let action = ActionItem(meetingID: meeting.id, title: "Suivi", status: .done, involvement: .follow)
    try db.save(meeting)
    try db.saveActions([action])
    let response = "{\"action_updates\":[{\"id\":\"\(action.id)\",\"status\":\"todo\"}]}"
    let app = storageCoordinator(root: root, database: db, provider: PipelineScriptedProvider([response]))
    await app.resume(meeting)
    #expect(app.processingPhase == .done)
    #expect(app.pendingMeeting?.folderPath.isEmpty == false)
    #expect(app.actions == [action])
    #expect(try db.loadAllActions() == [action])
}

@MainActor
@Test func failedDatabaseDeletionKeepsDocumentsAndAudio() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-delete-guard-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    let audio = root.appending(path: "audio")
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: audio.appending(path: "microphone.caf"))
    let meeting = Meeting(title: "Sync", status: .done, folderPath: "legacy", sessionDirPath: audio.path)
    try db.save(meeting)
    let app = storageCoordinator(root: root, database: db, provider: PipelineScriptedProvider([]))
    let vault = Vault(root: URL(fileURLWithPath: app.settings.vaultPath))
    try vault.write(VaultDocument(relativePath: "legacy/summary.md", type: .summary, markdown: "Résumé"))
    try fixtureSQL("""
        CREATE TRIGGER fail_delete BEFORE DELETE ON meeting
        BEGIN SELECT RAISE(ABORT, 'test failure'); END;
        """, at: db.path)
    app.deleteMeeting(meeting)
    #expect(app.storageError != nil)
    #expect(app.meetings.map(\.id) == [meeting.id])
    #expect(vault.exists(relativePath: "legacy/summary.md"))
    #expect(FileManager.default.fileExists(atPath: audio.appending(path: "microphone.caf").path))
}

@MainActor
@Test func lightweightHistoryPreservesTranscriptOnEditAndResume() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pepito-history-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appendingPathComponent("db"))
    let meeting = Meeting(title: "Original", status: .processing, tags: ["z", "a"],
                          transcript: "Transcript à conserver", userNotes: "Notes", summaryInstructions: "Consignes")
    try db.save(meeting)
    let app = storageCoordinator(root: root, database: db, provider: PipelineScriptedProvider([analysisJSON]))
    var summary = try #require(app.meetings.first)
    #expect(summary.transcript == nil)
    #expect(summary.tags == ["a", "z"])
    summary.title = "Corrigé"
    app.updateMeeting(summary)
    let stored = try #require(try db.loadMeeting(meeting.id))
    #expect(stored.transcript == meeting.transcript)
    #expect(stored.userNotes == "Notes")
    #expect(stored.summaryInstructions == "Consignes")
    #expect(stored.title == "Corrigé")
    app.setPending(try #require(app.meetings.first))
    #expect(app.pendingMeeting?.transcript == meeting.transcript)
    await app.resume(try #require(app.meetings.first))
    #expect(app.processingPhase == .done)
    #expect(try db.loadMeeting(meeting.id)?.transcript == meeting.transcript)
    #expect(app.meetings.first?.transcript == nil)
}
