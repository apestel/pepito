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

// Le texte live affiché est plafonné : sans ça, une réunion longue fait re-typographier tout le
// transcript à SwiftUI à chaque frame (100 % CPU sur le thread principal).
@MainActor
@Test func liveTranscriptTextIsCappedForDisplay() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-cap-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = MeetingCoordinator(
        settingsStore: SettingsStore(fileURL: root.appending(path: "settings.json")),
        database: Database(path: root.appending(path: "pepito.db")),
        tokenStore: InMemoryTokenStore(),
        recordingsRoot: root.appending(path: "recordings"),
        capture: MockCapturer()
    )

    let cap = MeetingCoordinator.liveDisplaySegmentCap
    let total = cap + 50
    coordinator.liveMicSegments = (0..<total).map {
        TranscriptSegment(start: Double($0), end: Double($0) + 0.5, text: "phrase \($0)")
    }

    let lines = coordinator.liveTranscriptText.split(separator: "\n")
    #expect(lines.count == cap)
    // On garde la *fin* : c'est ce que l'utilisateur regarde (auto-scroll en bas).
    #expect(lines.last?.hasSuffix("phrase \(total - 1)") == true)
    #expect(!coordinator.liveTranscriptText.contains("phrase 0\n"))
}

// Le spectrogramme ne se calcule que pendant un enregistrement ET quand une vue l'affiche : le
// popover de la barre de menu est son seul consommateur.
@MainActor
@Test func levelSamplingRunsOnlyWhenRecordingAndVisible() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-levels-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let coordinator = MeetingCoordinator(
        settingsStore: SettingsStore(fileURL: root.appending(path: "settings.json")),
        database: Database(path: root.appending(path: "pepito.db")),
        tokenStore: InMemoryTokenStore(),
        recordingsRoot: root.appending(path: "recordings"),
        capture: MockCapturer(),
        transcriberFactory: { MockTranscriber(segments: []) },
        liveTranscriberFactory: { _ in MockLiveTranscriber() }
    )

    // Popover ouvert hors enregistrement : rien à échantillonner.
    coordinator.levelsVisible = true
    #expect(coordinator.isSamplingLevels == false)

    // Enregistrement + popover ouvert : la boucle tourne.
    await coordinator.startRecording()
    #expect(coordinator.isSamplingLevels)

    // Popover fermé pendant l'enregistrement : la boucle s'arrête et l'historique est purgé.
    coordinator.levelsVisible = false
    #expect(coordinator.isSamplingLevels == false)
    #expect(coordinator.micSpectrogram.isEmpty)

    // Réouvert : elle repart.
    coordinator.levelsVisible = true
    #expect(coordinator.isSamplingLevels)

    // Arrêt de l'enregistrement, popover toujours ouvert : plus rien ne tourne.
    await coordinator.stopRecording()
    #expect(coordinator.isSamplingLevels == false)
}

// MARK: - Pré-brief ciblé par projet

@MainActor
@Test func preBriefRanksProjectMatchesFirst() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-prebrief-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = MeetingCoordinator(
        settingsStore: SettingsStore(fileURL: root.appending(path: "settings.json")),
        database: Database(path: root.appending(path: "pepito.db")),
        tokenStore: InMemoryTokenStore(),
        recordingsRoot: root.appending(path: "recordings"),
        capture: MockCapturer())
    app.settings.userName = "Antoine"
    app.settings.teamMembers = ["Marc"]

    let migration = Project(name: "Migration SI")
    app.saveProject(migration)

    let past = Meeting(id: UUID(), title: "Réunion passée", participants: ["Claire"], folderPath: "p")
    app.meetings = [past]

    let onProject = ActionItem(meetingID: past.id, projectID: migration.id, title: "Sur le projet", owner: "Zoé")
    let byOwner = ActionItem(meetingID: past.id, title: "Par le responsable", owner: "Claire")
    let noise = ActionItem(title: "Hors sujet", owner: "Inconnu")
    app.actions = [noise, byOwner, onProject]

    let meeting = Meeting(title: "Point", participants: ["Claire"], projectID: migration.id, folderPath: "f")
    let brief = app.relevantOpenActions(for: meeting)

    // Le projet prime sur le recoupement de participants ; « pour info » (owner inconnu) sort.
    #expect(brief.map(\.title) == ["Sur le projet", "Par le responsable"])

    // Réunion sans projet ni participants : plutôt que rien, on garde la liste triée par urgence.
    let blind = app.relevantOpenActions(for: Meeting(title: "Impromptue", folderPath: "f"))
    #expect(blind.count == 3)
}

@MainActor
@Test func preBriefPutsSeriesActionsFirst() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-prebrief-serie-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    // Réunions passées en base : `setCurrentProject` persiste et recharge la liste.
    let weekly = Meeting(title: "Weekly Produit", folderPath: "w")
    let ailleurs = Meeting(title: "Autre sujet", folderPath: "a")
    let database = Database(path: root.appending(path: "pepito.db"))
    database.save(weekly)
    database.save(ailleurs)
    let app = MeetingCoordinator(
        settingsStore: SettingsStore(fileURL: root.appending(path: "settings.json")),
        database: database,
        tokenStore: InMemoryTokenStore(),
        recordingsRoot: root.appending(path: "recordings"),
        capture: MockCapturer())

    let projet = Project(name: "Migration SI")
    app.saveProject(projet)

    let restant = ActionItem(meetingID: weekly.id, title: "Reste du weekly", priority: .low)
    let surProjet = ActionItem(meetingID: ailleurs.id, projectID: projet.id, title: "Sur le projet")
    let bruit = ActionItem(meetingID: ailleurs.id, title: "Sans lien", priority: .high)
    app.actions = [bruit, surProjet, restant]

    // Occurrence suivante de la série, rattachée au même projet.
    let suivante = Meeting(title: "Weekly Produit #12", projectID: projet.id, folderPath: "f")
    let brief = app.relevantOpenActions(for: suivante)

    // La série passe devant le projet malgré une priorité plus faible ; le bruit, même urgent, sort.
    #expect(brief.map(\.title) == ["Reste du weekly", "Sur le projet"])

    // Le séparateur de l'encart live : une seule action de tête vient de la série.
    app.setPending(suivante)
    app.setCurrentProject(projet.id)
    #expect(app.preBrief.map(\.title) == ["Reste du weekly", "Sur le projet"])
    #expect(app.preBriefSeriesCount == 1)
}
