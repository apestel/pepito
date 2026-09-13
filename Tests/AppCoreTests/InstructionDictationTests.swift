import Testing
import Foundation
import AVFoundation
import SQLite3
import os
import CaptureKit
import TranscriptionKit
import AIKit
import VaultKit
@testable import AppCore

@MainActor
private final class DictationCaptureSpy: AudioCapturing {
    var isRecording = false
    var startedSources: Set<AudioSource> = []
    var startCount = 0
    var stopCount = 0
    var directory: URL?
    var fails = false
    func start(sources: Set<AudioSource>, in directory: URL, microphoneEchoCancellation: Bool,
               systemAudioBundleID: String?, onMicBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
               onSystemBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?) async throws -> RecordingSession {
        startCount += 1
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("local audio".utf8).write(to: directory.appending(path: "microphone.caf"))
        if fails { throw CaptureError.notImplemented("Micro indisponible") }
        #expect(!microphoneEchoCancellation)
        #expect(onSystemBuffer == nil)
        #expect(systemAudioBundleID == nil)
        startedSources = sources
        isRecording = true
        return RecordingSession(directory: directory, sources: sources)
    }
    func stop() async throws { stopCount += 1; isRecording = false }
}

private final class DictationLiveSpy: LiveTranscribing, Sendable {
    let updates: AsyncStream<LiveTranscriptUpdate>
    let continuation: AsyncStream<LiveTranscriptUpdate>.Continuation
    private struct State { var segments: [TranscriptSegment] = []; var finishCount = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var finishCount: Int { state.withLock { $0.finishCount } }
    let fails: Bool
    init(fails: Bool = false) {
        self.fails = fails
        (updates, continuation) = AsyncStream.makeStream()
    }
    func start(locale: Locale) async throws {
        if fails { throw CaptureError.notImplemented("Transcription indisponible") }
    }
    func ingest(_ buffer: AVAudioPCMBuffer) {}
    func emit(final: String, volatile: String = "", error: String? = nil) {
        let segments = state.withLock { st in
            if !final.isEmpty { st.segments.append(TranscriptSegment(start: 0, end: 1, text: final)) }
            return st.segments
        }
        continuation.yield(LiveTranscriptUpdate(finalizedSegments: segments, volatileText: volatile, errorMessage: error))
    }
    func finish() async -> [TranscriptSegment] {
        continuation.finish()
        return state.withLock { st in st.finishCount += 1; return st.segments }
    }
}

@MainActor
private func waitForPhase(_ phase: InstructionDictation.Phase, in dictation: InstructionDictation) async throws {
    for _ in 0..<2_000 where dictation.phase != phase { await Task.yield() }
    try #require(dictation.phase == phase)
}

@MainActor
@Test func dictationReplacesVolatileWordsPreservesTypedTextAndCleansUp() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-dictation-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = DictationCaptureSpy()
    let live = DictationLiveSpy()
    let dictation = InstructionDictation(capture: capture, transcriberFactory: { live },
        requestPermission: { true }, temporaryRoot: root)
    dictation.text = "Texte saisi."
    dictation.start(locale: Locale(identifier: "fr-FR"))
    dictation.start(locale: Locale(identifier: "fr-FR")) // Double clic : une seule session.
    try await waitForPhase(.recording, in: dictation)
    #expect(capture.startCount == 1)
    #expect(capture.startedSources == [.microphone])
    live.emit(final: "Décisions en tête.", volatile: "Risques")
    for _ in 0..<2_000 where !dictation.text.contains("Risques") { await Task.yield() }
    #expect(dictation.text == "Texte saisi.\nDécisions en tête.\nRisques")
    live.emit(final: "", volatile: "Risques détaillés.")
    for _ in 0..<2_000 where !dictation.text.contains("détaillés") { await Task.yield() }
    #expect(dictation.text == "Texte saisi.\nDécisions en tête.\nRisques détaillés.")
    live.emit(final: "Risques détaillés.")
    async let firstStop: Void = dictation.stop()
    async let secondStop: Void = dictation.stop()
    _ = await (firstStop, secondStop)
    #expect(dictation.phase == .idle)
    #expect(dictation.text == "Texte saisi.\nDécisions en tête.\nRisques détaillés.")
    #expect(capture.stopCount == 1)
    #expect(live.finishCount == 1)
    #expect(!FileManager.default.fileExists(atPath: try #require(capture.directory).path))
    dictation.text = "Correction finale"
    #expect(dictation.text == "Correction finale")
}

@MainActor
@Test(arguments: ["permission", "speech", "capture", "stream"])
func dictationFailuresReturnToEditableTextAndReleaseResources(stage: String) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-dictation-failure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let capture = DictationCaptureSpy()
    capture.fails = stage == "capture"
    let live = DictationLiveSpy(fails: stage == "speech")
    let dictation = InstructionDictation(capture: capture, transcriberFactory: { live },
        requestPermission: { stage != "permission" }, temporaryRoot: root)
    dictation.text = "À conserver"
    dictation.start(locale: Locale(identifier: "fr-FR"))
    if stage == "stream" {
        try await waitForPhase(.recording, in: dictation)
        live.emit(final: "", error: "Flux interrompu")
    }
    try await waitForPhase(.idle, in: dictation)
    #expect(dictation.errorMessage != nil)
    #expect(dictation.text == "À conserver")
    #expect(!capture.isRecording)
    #expect(live.finishCount == 1)
    if let directory = capture.directory { #expect(!FileManager.default.fileExists(atPath: directory.path)) }
}

private actor DictationPermissionGate {
    var continuation: CheckedContinuation<Bool, Never>?
    private var requested: CheckedContinuation<Void, Never>?
    func request() async -> Bool {
        await withCheckedContinuation {
            continuation = $0
            requested?.resume()
            requested = nil
        }
    }
    func waitUntilRequested() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { requested = $0 }
    }
    func allow() { continuation?.resume(returning: true); continuation = nil }
}

@MainActor
@Test(.timeLimit(.minutes(1))) func closingWhilePermissionIsPendingNeverStartsMicrophoneLater() async throws {
    let gate = DictationPermissionGate()
    let capture = DictationCaptureSpy()
    let live = DictationLiveSpy()
    let dictation = InstructionDictation(capture: capture, transcriberFactory: { live }, requestPermission: { await gate.request() })
    dictation.start(locale: Locale(identifier: "fr-FR"))
    await gate.waitUntilRequested()
    let closing = Task { await dictation.stop() }
    try await waitForPhase(.stopping, in: dictation)
    await gate.allow()
    await closing.value
    #expect(dictation.phase == .idle)
    #expect(capture.startCount == 0)
    #expect(live.finishCount == 1)
    #expect(dictation.errorMessage == nil)
}

private final class InstructionProviderSpy: AIProvider, Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: [[ChatMessage]]())
    let checkMicrophoneStopped: @Sendable () async -> Bool
    var messages: [[ChatMessage]] { calls.withLock { $0 } }
    init(checkMicrophoneStopped: @escaping @Sendable () async -> Bool = { true }) {
        self.checkMicrophoneStopped = checkMicrophoneStopped
    }
    func complete(messages: [ChatMessage]) async throws -> ChatMessage {
        #expect(await checkMicrophoneStopped())
        calls.withLock { $0.append(messages) }
        return ChatMessage(role: .assistant, content: #"{"summary":"Résumé","actions":[]}"#)
    }
}

@Test func instructionsSupplementCustomPromptWithoutChangingFactualTranscript() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-instruction-prompt-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = InstructionProviderSpy()
    let instructions = "Privilégie les risques et rédige en anglais."
    let meeting = Meeting(title: "Sync", folderPath: "f", userNotes: "Une note factuelle", summaryInstructions: instructions)
    let prompt = "Mon prompt global. Notes : {{user_notes}}"
    _ = try await MeetingPipeline(provider: provider, vault: Vault(root: root)).process(
        meeting: meeting, transcript: "Transcript factuel", agenticPrompt: prompt, userNotes: meeting.userNotes)
    let messages = try #require(provider.messages.first)
    #expect(messages.first?.role == .system)
    #expect(messages.first?.content.contains(instructions) == true)
    #expect(messages.first?.content.contains("Une note factuelle") == true)
    #expect(messages.last == ChatMessage(role: .user, content: "Transcript factuel"))
    #expect(prompt == "Mon prompt global. Notes : {{user_notes}}")
    #expect(MeetingPipeline.instructionsBlock(nil).isEmpty)
    #expect(MeetingPipeline.instructionsBlock(" \n ").isEmpty)
}

@MainActor
@Test func dictatedInstructionsAreFinalizedBeforeAnalysisAndPersistedForRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-instruction-persist-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = Database(path: root.appending(path: "db"))
    let capture = DictationCaptureSpy()
    let live = DictationLiveSpy()
    let dictation = InstructionDictation(capture: capture, transcriberFactory: { live }, requestPermission: { true }, temporaryRoot: root)
    let provider = InstructionProviderSpy(checkMicrophoneStopped: { await !capture.isRecording })
    let app = MeetingCoordinator(settingsStore: SettingsStore(fileURL: root.appending(path: "settings.json")),
        database: db, tokenStore: InMemoryTokenStore(), capture: MockCapturer(), instructionDictation: dictation,
        calendar: MockCalendar(), providerFactory: { _, _ in provider })
    app.settings.vaultPath = root.appending(path: "vault").path
    let meeting = Meeting(title: "Sync", status: .awaitingName, transcript: "Compte rendu factuel", userNotes: "Anciennes notes", summaryInstructions: "Consigne tapée")
    try db.save(meeting)
    app.setPending(meeting)
    #expect(dictation.text == "Consigne tapée")
    app.startInstructionDictation()
    try await waitForPhase(.recording, in: dictation)
    live.emit(final: "Insiste sur les échéances.")
    await app.nameAndProcess(title: "Sync", tags: []) // Arrêt défensif même si l'UI désactive Valider.
    #expect(!dictation.isActive)
    #expect(capture.stopCount == 1)
    #expect(app.processingPhase == .done)
    let saved = try #require(Database(path: db.path).loadAll().first)
    #expect(saved.summaryInstructions == "Consigne tapée\nInsiste sur les échéances.")
    #expect(saved.userNotes == "Anciennes notes")
    #expect(saved.transcript == "Compte rendu factuel")
    let vault = Vault(root: URL(fileURLWithPath: app.settings.vaultPath))
    #expect(try vault.read(relativePath: PathBuilder.instructionsPath(meetingFolder: saved.folderPath)).markdown == saved.summaryInstructions)
    app.setPending(saved)
    await app.retryProcessing()
    #expect(provider.messages.count == 2)
    #expect(provider.messages[0] == provider.messages[1])
    dictation.text = "Correction manuelle"
    await app.finishInstructionEditing(for: saved.id)
    #expect(try Database(path: db.path).loadAll().first?.summaryInstructions == "Correction manuelle")
    #expect(provider.messages.count == 2) // Fermer/sauvegarder ne déclenche pas l'IA.
    dictation.text = ""
    await app.retryProcessing()
    #expect(try vault.read(relativePath: PathBuilder.instructionsPath(meetingFolder: saved.folderPath)).markdown.isEmpty)
    #expect(try db.loadAll().first?.userNotes == "Anciennes notes")
}

@Test func instructionMigrationPreservesOldNotesAndRemainsIdempotent() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "pepito-instruction-migration-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appending(path: "db")
    let id = UUID()
    var handle: OpaquePointer?
    try #require(sqlite3_open(path.path, &handle) == SQLITE_OK)
    let sql = """
        CREATE TABLE meeting(id TEXT PRIMARY KEY, title TEXT NOT NULL, started_at REAL NOT NULL,
        ended_at REAL, status TEXT NOT NULL, folder_path TEXT NOT NULL, session_dir TEXT,
        transcript TEXT, last_error TEXT, updated_at REAL NOT NULL, participants TEXT NOT NULL DEFAULT '',
        user_notes TEXT NOT NULL DEFAULT '');
        INSERT INTO meeting(id,title,started_at,status,folder_path,transcript,user_notes,updated_at)
        VALUES('\(id)','Ancienne',0,'awaitingName','legacy','Ancien transcript','Anciennes notes',0);
        """
    let rc = sqlite3_exec(handle, sql, nil, nil, nil)
    sqlite3_close(handle)
    try #require(rc == SQLITE_OK)
    let db = Database(path: path)
    var old = try #require(db.loadAll().first)
    #expect(old.summaryInstructions == nil)
    #expect(old.userNotes == "Anciennes notes")
    #expect(old.transcript == "Ancien transcript")
    // Le nouveau champ optionnel préserve aussi le décodage des anciennes représentations JSON.
    let encoded = try JSONEncoder().encode(old)
    #expect(try JSONDecoder().decode(Meeting.self, from: encoded) == old)
    old.summaryInstructions = "Synthèse courte"
    try db.save(old)
    for _ in 0..<2 {
        #expect(try Database(path: path).loadAll().first == old)
    }
}
