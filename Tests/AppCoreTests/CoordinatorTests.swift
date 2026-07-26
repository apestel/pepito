import Testing
import Foundation
import AVFoundation
import CaptureKit
import TranscriptionKit
@testable import AppCore

// Capture factice : crée le dossier + un fichier micro (le MockTranscriber ignore le contenu).
@MainActor
final class MockCapturer: AudioCapturing {
    var isRecording = false
    var startedSources: Set<AudioSource> = []

    func start(
        sources: Set<AudioSource>,
        in directory: URL,
        microphoneEchoCancellation: Bool,
        systemAudioBundleID: String?,
        onMicBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        onSystemBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) async throws -> RecordingSession {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Fichier non vide : le MockTranscriber ignore le contenu, mais le coordinateur saute
        // désormais les fichiers vides, donc on écrit quelques octets.
        FileManager.default.createFile(
            atPath: directory.appending(path: "microphone.caf").path,
            contents: Data([0, 1, 2, 3])
        )
        isRecording = true
        startedSources = sources
        return RecordingSession(directory: directory, sources: sources)
    }

    func stop() async throws { isRecording = false }
}

@MainActor
@Test func coordinatorRunsCaptureTranscriptionAndPipeline() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-coord-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultDir = root.appending(path: "vault")

    let mockMicLive = MockLiveTranscriber()
    let mockSystemLive = MockLiveTranscriber()
    let coordinator = MeetingCoordinator(
        settingsStore: SettingsStore(fileURL: root.appending(path: "settings.json")),
        database: Database(path: root.appending(path: "pepito.db")),
        tokenStore: InMemoryTokenStore(),
        recordingsRoot: root.appending(path: "recordings"),
        capture: MockCapturer(),
        transcriberFactory: {
            MockTranscriber(segments: [
                TranscriptSegment(start: 0, end: 2, text: "Il faut préparer le budget."),
            ])
        },
        liveTranscriberFactory: { source in source == .microphone ? mockMicLive : mockSystemLive },
        providerFactory: { _, _ in
            PipelineScriptedProvider([
                #"{"summary":"Résumé","actions":[{"title":"Préparer le budget","owner":"Alice"}]}"#,
            ])
        }
    )
    coordinator.settings.vaultPath = vaultDir.path

    // Démarrage sans titre : le nom est saisi à l'arrêt (fenêtre de nommage).
    await coordinator.startRecording()
    #expect(coordinator.isRecording)

    // Transcript live labellisé par source : micro → « Moi », système → « Interlocuteurs ».
    mockMicLive.emit(finalized: "Bonjour tout le monde", at: 0)
    mockSystemLive.emit(finalized: "Oui je vous entends", at: 1)
    // Attendre que LES DEUX sources aient propagé (streams async distincts) — sinon lecture partielle.
    for _ in 0..<200 where !(coordinator.liveTranscriptText.contains("Moi")
        && coordinator.liveTranscriptText.contains("Interlocuteurs")) { await Task.yield() }
    #expect(coordinator.liveTranscriptText == "Moi: Bonjour tout le monde\nInterlocuteurs: Oui je vous entends")

    // Arrêt → en attente de nom, transcript live figé.
    await coordinator.stopRecording()
    #expect(coordinator.isRecording == false)
    #expect(coordinator.meetings.first?.status == .awaitingName)

    // Nommage + tags → pipeline complet.
    await coordinator.nameAndProcess(title: "Sync budget", tags: ["budget"])
    #expect(coordinator.isProcessing == false)

    // Une réunion persistée, au statut terminé, avec ses tags.
    #expect(coordinator.meetings.count == 1)
    #expect(coordinator.meetings.first?.status == .done)
    #expect(coordinator.meetings.first?.endedAt != nil)
    #expect(coordinator.meetings.first?.tags == ["budget"])
    #expect(coordinator.allTags.contains("budget"))

    // Une action extraite et disponible pour le suivi.
    #expect(coordinator.actions.count == 1)
    #expect(coordinator.actions.first?.title == "Préparer le budget")
    #expect(coordinator.openActions.count == 1)

    // Le transcript écrit dans le Vault provient du LIVE (pas de re-transcription), labellisé et fusionné.
    let vault = Vault(root: vaultDir)
    let folder = coordinator.meetings.first!.folderPath
    let transcriptPath = PathBuilder.transcriptPath(meetingFolder: folder)
    #expect(vault.exists(relativePath: transcriptPath))
    let doc = try vault.read(relativePath: transcriptPath, type: .meetingNote)
    #expect(doc.markdown == "Moi: Bonjour tout le monde\nInterlocuteurs: Oui je vous entends")

    // Les tags saisis se retrouvent dans le front-matter du summary.
    let summary = try vault.read(relativePath: PathBuilder.summaryPath(meetingFolder: folder), type: .summary)
    #expect(summary.frontMatter["tags"]?.contains("budget") == true)

    // Résumé relu pour l'UI : corps Markdown seul (front-matter retiré), nil si rien dans le Vault.
    #expect(coordinator.summaryMarkdown(for: coordinator.meetings.first!) == "Résumé")
    #expect(coordinator.summaryMarkdown(for: Meeting(title: "Jamais analysée")) == nil)

    // Éditions manuelles (fiche réunion) : participants, tags, action — persistées en base.
    var edited = coordinator.meetings.first!
    edited.participants = ["Alice", "Bob"]
    edited.tags = ["budget", "q3"]
    coordinator.updateMeeting(edited)
    var action = coordinator.actions.first!
    action.title = "Préparer le budget Q3"
    action.owner = "Bob"
    action.status = .inProgress
    coordinator.updateAction(action)

    let reloaded = Database(path: root.appending(path: "pepito.db"))
    #expect(reloaded.loadAll().first?.participants == ["Alice", "Bob"])
    #expect(reloaded.loadAll().first?.tags == ["budget", "q3"])
    #expect(coordinator.allTags.contains("q3"))
    #expect(reloaded.loadAllActions().first?.title == "Préparer le budget Q3")
    #expect(reloaded.loadAllActions().first?.owner == "Bob")
    #expect(reloaded.loadAllActions().first?.status == .inProgress)
}

@MainActor
@Test func resumesAfterAnalysisFailure() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-resume-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let vaultDir = root.appending(path: "vault")

    let mockMicLive = MockLiveTranscriber()
    let mockSystemLive = MockLiveTranscriber()
    // L'analyse IA échoue une fois puis réussit.
    let provider = FailingOnceProvider(
        success: #"{"summary":"Résumé","actions":[{"title":"Préparer le budget"}]}"#)
    let coordinator = MeetingCoordinator(
        settingsStore: SettingsStore(fileURL: root.appending(path: "settings.json")),
        database: Database(path: root.appending(path: "pepito.db")),
        tokenStore: InMemoryTokenStore(),
        recordingsRoot: root.appending(path: "recordings"),
        capture: MockCapturer(),
        transcriberFactory: { MockTranscriber(segments: []) },
        liveTranscriberFactory: { source in source == .microphone ? mockMicLive : mockSystemLive },
        providerFactory: { _, _ in provider }
    )
    coordinator.settings.vaultPath = vaultDir.path

    await coordinator.startRecording()
    mockMicLive.emit(finalized: "Bonjour tout le monde", at: 0)
    for _ in 0..<200 where coordinator.liveTranscriptText.isEmpty { await Task.yield() }
    await coordinator.stopRecording()
    #expect(coordinator.pendingMeeting?.transcript?.isEmpty == false)

    // 1er passage : l'analyse échoue → réunion reprenable, aucune action, phase en échec.
    await coordinator.nameAndProcess(title: "Sync budget", tags: ["budget"])
    #expect(coordinator.meetings.first?.status == .processing)
    #expect(coordinator.meetings.first?.status.isResumable == true)
    #expect(coordinator.meetings.first?.lastError != nil)
    #expect(coordinator.processingPhase?.isFailed == true)
    #expect(coordinator.actions.isEmpty)

    // Reprise : réutilise le transcript persisté, ré-exécute l'analyse → terminé.
    await coordinator.retryProcessing()
    #expect(coordinator.meetings.first?.status == .done)
    #expect(coordinator.meetings.first?.lastError == nil)
    #expect(coordinator.actions.count == 1)
    #expect(coordinator.meetings.first?.tags == ["budget"])
}
