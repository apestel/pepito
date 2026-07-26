import Foundation
import Observation
import os
import CaptureKit
import TranscriptionKit
import AIKit
import VaultKit
import ActionKit
import MailKit

/// Contrôleur applicatif principal (@MainActor, observable) : réglages, enregistrement, et
/// pipeline de bout en bout capture → transcription → analyse agentic. Point d'entrée unique de
/// l'UI. Les dépendances (transcripteur, provider) sont injectables pour tests/previews.
@MainActor
@Observable
public final class MeetingCoordinator {
    // Réglages / configuration (Phase 6)
    public var settings: Settings
    public var tokenInput: String = ""
    public var tokenPresent: Bool = false
    public var connectionStatus: String?

    // Données (Phase 7)
    public var meetings: [Meeting] = []
    public var actions: [ActionItem] = []
    /// Tags connus (liste réutilisable), pour le sélecteur de la fenêtre de nommage.
    public var allTags: [String] = []

    /// Notes prises par l'utilisateur pendant la réunion en cours (fenêtre live + nommage). Enrichies
    /// par l'IA (Phase C). Réinitialisées à chaque nouvel enregistrement.
    public var draftNotes: String = ""

    /// Pré-brief (Phase D) : actions ouvertes des réunions passées liées aux mêmes participants,
    /// calculées au démarrage d'un enregistrement (« la dernière fois, il restait à… »).
    public var preBrief: [ActionItem] = []

    /// Triage de la boîte mail : en cours, dernier bilan/erreur, historique des revues (plus
    /// récente en tête) et date de la dernière revue produite (pour la sélectionner dans l'UI).
    public var isTriagingMail: Bool = false
    public var mailStatus: String?
    public var mailReviews: [MailReviewSummary] = []
    public var lastMailReviewDate: String?

    // État d'exécution
    public var isRecording: Bool = false
    public var isProcessing: Bool = false
    public var statusMessage: String?
    /// Étape de traitement en cours, pour la barre de progression de la fenêtre de nommage.
    public var processingPhase: ProcessingPhase?

    // Transcript live par source (mis à jour pendant l'enregistrement)
    public var liveMicSegments: [TranscriptSegment] = []
    public var liveSystemSegments: [TranscriptSegment] = []
    public var liveMicVolatile: String = ""
    public var liveSystemVolatile: String = ""
    /// Spectrogramme roulant par source : chaque élément est une colonne (bandes de fréquence 0…1),
    /// la plus récente en fin. Alimente la visualisation live.
    public var micSpectrogram: [[Float]] = []
    public var systemSpectrogram: [[Float]] = []
    /// Texte live affichable : les deux sources fusionnées **par ordre chronologique** et
    /// labellisées (Moi / Interlocuteurs). Une ligne par prise de parole (chaque segment finalisé
    /// = une pause), l'étiquette n'étant répétée qu'au changement de locuteur.
    public var liveTranscriptText: String {
        // Retire le bleed micro (doublons de la sortie HP) aussi en direct.
        let cleanMic = BleedFilter.micWithoutBleed(mic: liveMicSegments, system: liveSystemSegments)
        let labeled = cleanMic.map { ("Moi", $0) } + liveSystemSegments.map { ("Interlocuteurs", $0) }
        let sorted = labeled.sorted { $0.1.start < $1.1.start }

        var lines: [String] = []
        var lastSpeaker: String?
        func append(_ speaker: String, _ text: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            lines.append(speaker == lastSpeaker ? t : "\(speaker): \(t)")
            lastSpeaker = speaker
        }
        for (speaker, seg) in sorted { append(speaker, seg.text) }
        // Fragments encore en cours de parole (non finalisés), affichés en fin.
        append("Moi", liveMicVolatile)
        append("Interlocuteurs", liveSystemVolatile)
        return lines.joined(separator: "\n")
    }

    private let settingsStore: SettingsStore
    private let database: Database
    private let tokenStore: any TokenStore
    private let capture: any AudioCapturing
    private let calendar: any CalendarProviding
    /// Agenda de l'événement calendrier de la réunion en cours (contexte IA). ponytail: en mémoire
    /// pour la session ; non repersisté, donc une reprise après relancement l'analyse sans agenda.
    private var currentAgenda: String = ""
    private let makeTranscriber: @Sendable () -> any Transcriber
    private let makeLiveTranscriber: @Sendable (AudioSource) -> any LiveTranscribing
    private let makeProviderOverride: (@Sendable (Settings, String) -> (any AIProvider)?)?
    private let recordingsRoot: URL

    private let tokenAccount = "default"
    private var currentMeeting: Meeting?
    private var currentSessionDir: URL?
    private var isStopping = false
    private var liveMic: (any LiveTranscribing)?
    private var liveSystem: (any LiveTranscribing)?
    private var liveTasks: [Task<Void, Never>] = []
    private let meter = SpectrumMeter()
    private var levelTask: Task<Void, Never>?
    private let maxColumns = 140
    /// Vu depuis le thread audio : au moins un buffer système est arrivé (diagnostic capture).
    private let systemBufferSeen = OSAllocatedUnfairLock(initialState: false)
    private let log = Log.logger("MeetingCoordinator")

    public init(
        settingsStore: SettingsStore = .defaultLocation(),
        database: Database = .defaultLocation(),
        tokenStore: any TokenStore = KeychainTokenStore(),
        recordingsRoot: URL? = nil,
        capture: (any AudioCapturing)? = nil,
        calendar: (any CalendarProviding)? = nil,
        transcriberFactory: @escaping @Sendable () -> any Transcriber = {
            SpeechAnalyzerTranscriber(log: { AppLog.shared.log("Transcription: \($0)") })
        },
        liveTranscriberFactory: @escaping @Sendable (AudioSource) -> any LiveTranscribing = { source in
            SpeechAnalyzerLiveTranscriber(log: { AppLog.shared.log("Live \(source.rawValue): \($0)") })
        },
        providerFactory: (@Sendable (Settings, String) -> (any AIProvider)?)? = nil
    ) {
        self.settingsStore = settingsStore
        self.database = database
        self.tokenStore = tokenStore
        self.capture = capture ?? CaptureController(log: { AppLog.shared.log($0) })
        self.calendar = calendar ?? EventKitCalendar()
        self.makeTranscriber = transcriberFactory
        self.makeLiveTranscriber = liveTranscriberFactory
        self.makeProviderOverride = providerFactory
        self.recordingsRoot = recordingsRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "Pepito/recordings")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "Pepito/recordings")

        self.settings = settingsStore.load()
        self.meetings = database.loadAll()
        self.actions = database.loadAllActions()
        self.allTags = database.allTags()
        self.mailReviews = database.mailReviews()
        self.tokenPresent = ((try? tokenStore.token(for: tokenAccount)) ?? nil) != nil
    }

    // MARK: - Réglages

    public func saveSettings() {
        do { try settingsStore.save(settings) }
        catch { log.error("Sauvegarde réglages: \(error, privacy: .public)") }
    }

    public func commitToken() {
        let value = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        try? tokenStore.setToken(value.isEmpty ? nil : value, for: tokenAccount)
        tokenPresent = !value.isEmpty
        tokenInput = ""
    }

    public func testConnection() async {
        connectionStatus = "Test en cours…"
        switch await AppCore.testConnection(settings: settings, token: currentToken()) {
        case .success(let model): connectionStatus = "✅ Connecté (\(model))"
        case .failure(let message): connectionStatus = "❌ \(message)"
        }
    }

    // MARK: - Enregistrement + pipeline

    /// Démarre un enregistrement immédiatement. Le nom et les tags sont saisis **à l'arrêt** (fenêtre
    /// de nommage) ; un titre temporaire est utilisé d'ici là.
    public func startRecording() async {
        guard !isRecording else { return }
        let started = Date()
        let tempTitle = "Réunion du " + Self.titleDateFormatter.string(from: started)
        let sessionDir = recordingsRoot.appending(path: UUID().uuidString)
        processingPhase = nil
        draftNotes = ""   // notes propres à la nouvelle réunion

        let sources = enabledSources()
        AppLog.shared.log("Démarrage enregistrement « \(tempTitle) » sources=\(sources.map(\.rawValue).sorted().joined(separator: "+")) dir=\(sessionDir.path)")

        // Transcription live par source (best effort : un échec live n'empêche pas l'enregistrement).
        liveMicSegments = []
        liveSystemSegments = []
        liveMicVolatile = ""
        liveSystemVolatile = ""
        liveMic = await startLive(for: .microphone) { [weak self] u in
            self?.liveMicSegments = u.finalizedSegments; self?.liveMicVolatile = u.volatileText
        }
        if sources.contains(.system) {
            liveSystem = await startLive(for: .system) { [weak self] u in
                self?.liveSystemSegments = u.finalizedSegments; self?.liveSystemVolatile = u.volatileText
            }
        }
        let micLive = liveMic
        let systemLive = liveSystem

        let meter = self.meter
        let systemSeen = self.systemBufferSeen
        systemSeen.withLock { $0 = false }
        do {
            try await capture.start(
                sources: sources,
                in: sessionDir,
                microphoneEchoCancellation: settings.echoCancellation == .osVoiceProcessing,
                systemAudioBundleID: settings.systemCaptureBundleID,
                onMicBuffer: { buffer in micLive?.ingest(buffer); meter.push(buffer, source: .microphone) },
                onSystemBuffer: { buffer in
                    systemLive?.ingest(buffer)
                    meter.push(buffer, source: .system)
                    systemSeen.withLock { $0 = true }
                }
            )
        } catch {
            statusMessage = "Erreur capture : \(error.localizedDescription)"
            AppLog.shared.log("Erreur capture : \(AppLog.describe(error))", level: "ERROR")
            await stopLive()
            return
        }

        // Contexte calendrier (best effort) : pré-remplit titre + participants, mémorise l'agenda.
        let event = await calendar.currentOrImminentEvent()
        currentAgenda = event?.agenda ?? ""
        let meeting = Meeting(
            title: (event?.title.isEmpty == false) ? event!.title : tempTitle,
            startedAt: started,
            participants: event?.participants ?? [],
            status: .recording,
            sessionDirPath: sessionDir.path
        )
        currentMeeting = meeting
        currentSessionDir = sessionDir
        preBrief = relevantOpenActions(for: meeting)   // « la dernière fois, il restait à… »
        isRecording = true
        persist(meeting)   // résilience : la réunion existe en base dès le départ
        startLevelSampling()

        let activeSources = capture.startedSources
        if activeSources.contains(.system) {
            statusMessage = "Enregistrement (micro + système)…"
            watchSystemBuffers()
        } else if activeSources.contains(.microphone) {
            statusMessage = "Enregistrement (micro seul — sortie système non autorisée)…"
        } else {
            statusMessage = "Enregistrement en cours…"
        }
    }

    /// Le tap système a démarré : vérifie qu'il délivre réellement de l'audio. S'il reste muet,
    /// c'est le symptôme « j'entends le son mais rien dans l'interface » — on le trace explicitement.
    private func watchSystemBuffers() {
        let seen = systemBufferSeen
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.isRecording else { return }
            if seen.withLock({ $0 }) {
                AppLog.shared.log("Capture système : audio reçu ✅")
            } else {
                AppLog.shared.log(
                    "Capture système : tap démarré mais AUCUN buffer après 3 s — sortie muette ou "
                    + "permission audio système à vérifier (Réglages Système › Confidentialité).",
                    level: "WARN"
                )
            }
        }
    }

    /// Arrête l'enregistrement : teardown audio + finalisation du transcript live, puis passe la
    /// réunion en `awaitingName`. L'analyse ne démarre qu'après nommage (`nameAndProcess`).
    public func stopRecording() async {
        // Garde de ré-entrance : un arrêt lent (teardown audio) ne doit pas être relancé à chaque
        // clic — sinon les appels s'empilent et se bloquent mutuellement.
        guard var meeting = currentMeeting, !isStopping else { return }
        isStopping = true
        isRecording = false   // reflète l'arrêt immédiatement dans l'UI, avant le teardown
        processingPhase = nil
        statusMessage = "Arrêt en cours…"
        AppLog.shared.log("Arrêt de l'enregistrement : « \(meeting.title) »")
        try? await capture.stop()
        // Le transcript vient d'abord du LIVE (déjà calculé pendant l'enregistrement). Le repli
        // fichier / AEC hors-ligne, s'il s'applique, sera fait dans le pipeline (après nommage).
        let liveSegments = await stopLive()
        meeting.endedAt = Date()
        let live = TranscriptFormatter.plainText(liveSegments)
        meeting.transcript = live.isEmpty ? nil : live
        meeting.userNotes = draftNotes
        meeting.status = .awaitingName
        currentMeeting = meeting
        persist(meeting)
        isStopping = false
        statusMessage = "En attente de nom…"
    }

    /// Nomme la réunion arrêtée, enregistre ses tags, puis lance le pipeline complet.
    public func nameAndProcess(title: String, tags: [String]) async {
        guard var meeting = currentMeeting else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = trimmed.isEmpty ? meeting.title : trimmed
        let cleanTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        meeting.title = cleanTitle
        meeting.folderPath = PathBuilder.meetingFolder(date: meeting.startedAt, title: cleanTitle)
        meeting.tags = cleanTags
        meeting.userNotes = draftNotes   // notes éventuellement éditées dans la fenêtre de nommage
        database.addTags(cleanTags)
        allTags = database.allTags()
        currentMeeting = meeting
        await runPipeline(meeting)
    }

    /// Reprend une réunion interrompue (échec d'une étape). Réutilise le transcript persisté pour
    /// éviter de re-transcrire ; ré-exécute à partir de l'étape appropriée.
    public func resume(_ meeting: Meeting) async {
        guard meeting.status.isResumable, !isProcessing else { return }
        currentMeeting = meeting
        currentSessionDir = meeting.sessionDirPath.map { URL(fileURLWithPath: $0) }
        AppLog.shared.log("Reprise du traitement : « \(meeting.title) » (étape \(meeting.status.rawValue))")
        await runPipeline(meeting)
    }

    /// Runner d'étapes : transcription → analyse IA (+ écriture Vault). Persiste `status` à chaque
    /// étape ; un échec laisse la réunion reprenable (`lastError` renseigné, `status` sur l'étape).
    private func runPipeline(_ meetingIn: Meeting) async {
        var meeting = meetingIn
        isProcessing = true
        meeting.lastError = nil

        // 1. Transcription (instantanée si le live a produit ; sinon fichiers / AEC hors-ligne).
        let transcript: String
        do {
            processingPhase = .transcribing
            meeting.status = .transcribing
            statusMessage = "Transcription…"
            persist(meeting)
            transcript = try await resolveTranscript(for: meeting)
            meeting.transcript = transcript
            AppLog.shared.log("Transcription OK : \(transcript.count) car.")
            writeTranscriptToVault(transcript, folder: meeting.folderPath)
        } catch {
            fail(&meeting, phase: "Transcription", error: error)
            return
        }

        // 2. Analyse IA (le pipeline écrit aussi résumé + plan d'action dans le Vault).
        do {
            processingPhase = .analyzing
            meeting.status = .processing
            statusMessage = "Analyse IA…"
            persist(meeting)
            guard let provider = provider() else { throw CoordinatorError.notConfigured }
            AppLog.shared.log("Analyse IA via \(settings.aiBaseURL) (modèle \(settings.aiModel))…")
            let pipeline = MeetingPipeline(provider: provider, vault: vault())
            let followUp = relevantOpenActions(for: meeting)
            let result = try await pipeline.process(
                meeting: meeting,
                transcript: transcript,
                agenticPrompt: settings.agenticPrompt,
                context: currentAgenda,
                userNotes: meeting.userNotes,
                openActions: Self.openActionsText(followUp)
            )
            actions.removeAll { $0.meetingID == meeting.id }   // idempotent en cas de reprise
            actions.append(contentsOf: result.actions)
            database.saveActions(result.actions)
            // Suivi cross-réunion : appliquer les résolutions détectées sur les actions passées.
            for update in result.actionUpdates { updateActionStatus(update.id, to: update.status) }
            meeting.status = .done
            processingPhase = .done
            statusMessage = "Terminé — \(result.actions.count) action(s)."
            AppLog.shared.log("Analyse OK : \(result.actions.count) action(s), \(result.documentsWritten.count) document(s)")
        } catch {
            fail(&meeting, phase: "Analyse IA", error: error)
            return
        }

        persist(meeting)
        currentMeeting = meeting   // conservé pour « Ouvrir l'emplacement » depuis la fenêtre de nommage
        isProcessing = false
    }

    /// Réunion en cours de nommage/traitement (pour la fenêtre de nommage).
    public var pendingMeeting: Meeting? { currentMeeting }

    /// Relance le pipeline sur la réunion en cours (bouton « Réessayer » après un échec).
    public func retryProcessing() async {
        guard let meeting = currentMeeting, !isProcessing else { return }
        await runPipeline(meeting)
    }

    /// Prépare la reprise d'une réunion depuis la timeline : la fenêtre de nommage l'affiche (formulaire
    /// si elle n'est pas nommée, sinon état d'échec avec « Réessayer »).
    public func setPending(_ meeting: Meeting) {
        currentMeeting = meeting
        currentSessionDir = meeting.sessionDirPath.map { URL(fileURLWithPath: $0) }
        processingPhase = meeting.lastError.map { .failed($0) }
    }

    /// Choisit la meilleure source de transcript : AEC hors-ligne (si configurée) puis live persisté,
    /// puis repli transcription des fichiers.
    private func resolveTranscript(for meeting: Meeting) async throws -> String {
        let sessionDir = meeting.sessionDirPath.map { URL(fileURLWithPath: $0) }
        if settings.echoCancellation == .offlineReference, let dir = sessionDir,
           let cleaned = await transcribeWithOfflineAEC(in: dir) {
            AppLog.shared.log("Transcript issu des fichiers avec AEC hors-ligne : \(cleaned.count) segment(s)")
            return TranscriptFormatter.plainText(cleaned)
        }
        if let live = meeting.transcript, !live.isEmpty {
            AppLog.shared.log("Transcript issu du live")
            return live
        }
        guard let dir = sessionDir else { throw CoordinatorError.noAudio }
        AppLog.shared.log("Aucun segment live → repli transcription fichier")
        return TranscriptFormatter.plainText(try await transcribeSources(in: dir))
    }

    /// Écrit le transcript dans le Vault (best effort, journalisé).
    private func writeTranscriptToVault(_ transcript: String, folder: String) {
        guard !settings.vaultPath.isEmpty else {
            AppLog.shared.log("vaultPath vide — transcript non écrit dans le Vault", level: "WARN")
            return
        }
        do {
            try Vault(root: URL(fileURLWithPath: settings.vaultPath)).write(VaultDocument(
                relativePath: PathBuilder.transcriptPath(meetingFolder: folder),
                type: .meetingNote,
                markdown: transcript
            ))
            AppLog.shared.log("Transcript écrit dans le Vault")
        } catch {
            AppLog.shared.log("Échec écriture Vault : \(AppLog.describe(error))", level: "WARN")
        }
    }

    /// URL du dossier de la réunion dans le Vault (pour « Ouvrir l'emplacement »), sinon dossier audio.
    /// Supprime une réunion : documents du Vault, fichiers audio, et lignes en base (actions + tags
    /// en cascade). Action **destructive** — l'UI confirme avant d'appeler.
    public func deleteMeeting(_ meeting: Meeting) {
        // Ne pas supprimer la réunion en cours d'enregistrement/traitement.
        guard !(currentMeeting?.id == meeting.id && (isRecording || isProcessing)) else { return }

        // Dossier du Vault — garde : jamais la racine (folderPath vide → on effacerait tout le Vault).
        if !settings.vaultPath.isEmpty, !meeting.folderPath.isEmpty {
            let folder = URL(fileURLWithPath: settings.vaultPath).appending(path: meeting.folderPath)
            try? FileManager.default.removeItem(at: folder)
        }
        // Fichiers audio de la session.
        if let dir = meeting.sessionDirPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dir))
        }

        database.delete(meeting.id)
        if currentMeeting?.id == meeting.id { currentMeeting = nil }
        meetings = database.loadAll()
        actions = database.loadAllActions()
        AppLog.shared.log("Réunion supprimée : « \(meeting.title) »")
    }

    /// Résumé Markdown d'une réunion, lu depuis le Vault (`summary.md`, front-matter retiré).
    /// `nil` si le Vault n'est pas configuré ou si l'analyse n'a rien écrit.
    public func summaryMarkdown(for meeting: Meeting) -> String? {
        guard !settings.vaultPath.isEmpty, !meeting.folderPath.isEmpty else { return nil }
        let vault = Vault(root: URL(fileURLWithPath: settings.vaultPath))
        let path = PathBuilder.summaryPath(meetingFolder: meeting.folderPath)
        guard let doc = try? vault.read(relativePath: path, type: .summary) else { return nil }
        let markdown = doc.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return markdown.isEmpty ? nil : markdown
    }

    /// Réécrit `summary.md` avec le Markdown édité à la main, front-matter conservé. Le Vault
    /// reste la source de vérité : rien n'est dupliqué en base.
    public func saveSummary(_ markdown: String, for meeting: Meeting) {
        guard !settings.vaultPath.isEmpty, !meeting.folderPath.isEmpty else {
            statusMessage = "Vault non configuré : résumé non enregistré."
            return
        }
        let vault = self.vault()
        let path = PathBuilder.summaryPath(meetingFolder: meeting.folderPath)
        let existing = try? vault.read(relativePath: path, type: .summary)
        do {
            try vault.write(VaultDocument(
                relativePath: path,
                type: .summary,
                frontMatter: existing?.frontMatter ?? ["title": meeting.title],
                markdown: markdown))
        } catch {
            statusMessage = "Résumé non enregistré : \(error.localizedDescription)"
            AppLog.shared.log("Écriture du résumé échouée : \(AppLog.describe(error))", level: "ERROR")
        }
    }

    public func location(for meeting: Meeting) -> URL? {
        if !settings.vaultPath.isEmpty, !meeting.folderPath.isEmpty {
            return URL(fileURLWithPath: settings.vaultPath).appending(path: meeting.folderPath)
        }
        return meeting.sessionDirPath.map { URL(fileURLWithPath: $0) }
    }

    /// URL du journal fichier (pour l'ouvrir depuis l'UI).
    public var logFileURL: URL { AppLog.shared.fileURL }

    /// Démarre un transcripteur live pour une source et route ses mises à jour vers `apply`.
    private func startLive(
        for source: AudioSource,
        apply: @escaping @MainActor (LiveTranscriptUpdate) -> Void
    ) async -> (any LiveTranscribing)? {
        let live = makeLiveTranscriber(source)
        do {
            try await live.start(locale: Locale(identifier: settings.transcriptionLocaleIdentifier))
        } catch {
            AppLog.shared.log("Transcript live (\(source.rawValue)) indisponible : \(AppLog.describe(error))", level: "WARN")
            return nil
        }
        let task = Task { [weak self] in
            for await update in live.updates {
                _ = self
                apply(update)
            }
        }
        liveTasks.append(task)
        return live
    }

    /// Échantillonne le spectre à ~30 Hz et pousse une colonne dans les spectrogrammes roulants.
    /// La FFT tourne sur un thread de fond (`Task.detached`) pour ne pas partager le MainActor avec
    /// l'arrivée des résultats de transcription : sinon un burst de transcript fige le spectre (et
    /// vice-versa). On ne repasse sur le MainActor que pour publier les colonnes calculées.
    private func startLevelSampling() {
        micSpectrogram = []
        systemSpectrogram = []
        let meter = self.meter
        levelTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                let s = meter.sample()   // FFT hors du thread principal
                await MainActor.run { [weak self] in
                    guard let self, self.isRecording else { return }
                    self.micSpectrogram = Self.appendCapped(self.micSpectrogram, s.mic, max: self.maxColumns)
                    self.systemSpectrogram = Self.appendCapped(self.systemSpectrogram, s.system, max: self.maxColumns)
                }
            }
        }
    }

    private static func appendCapped<T>(_ arr: [T], _ value: T, max: Int) -> [T] {
        var a = arr
        a.append(value)
        if a.count > max { a.removeFirst(a.count - max) }
        return a
    }

    /// Finalise les transcripteurs live et renvoie leurs segments finalisés, labellisés par source
    /// et fusionnés par timestamp.
    @discardableResult
    private func stopLive() async -> [TranscriptSegment] {
        let micSegments = (await liveMic?.finish() ?? []).map { seg -> TranscriptSegment in
            var s = seg; s.speakerLabel = "Moi"; return s
        }
        let systemSegments = (await liveSystem?.finish() ?? []).map { seg -> TranscriptSegment in
            var s = seg; s.speakerLabel = "Interlocuteurs"; return s
        }
        liveTasks.forEach { $0.cancel() }
        liveTasks = []
        levelTask?.cancel()
        levelTask = nil
        liveMic = nil
        liveSystem = nil

        // Retire le bleed : les segments micro qui ne font que recapter la sortie HP (doublons).
        let cleanMic = BleedFilter.micWithoutBleed(mic: micSegments, system: systemSegments)
        if cleanMic.count < micSegments.count {
            AppLog.shared.log("Bleed micro retiré : \(micSegments.count - cleanMic.count) segment(s) doublon(s)")
        }
        return (cleanMic + systemSegments).sorted { $0.start < $1.start }
    }

    /// Échec d'une étape : on **conserve** `status` sur l'étape fautive et on renseigne `lastError`,
    /// de sorte que la réunion reste reprenable (`resume`). `currentMeeting` est gardé pour permettre
    /// « Réessayer » directement depuis la fenêtre de nommage.
    private func fail(_ meeting: inout Meeting, phase: String, error: Error) {
        let message = "\(phase) : \(error.localizedDescription)"
        meeting.lastError = message
        statusMessage = "\(phase) échouée — \(error.localizedDescription)"
        processingPhase = .failed(message)
        AppLog.shared.log("\(phase) échouée : \(AppLog.describe(error))", level: "ERROR")
        persist(meeting)
        currentMeeting = meeting
        isProcessing = false
        isStopping = false
    }

    /// AEC hors-ligne (NLMS) : nettoie le micro avec la sortie système comme référence, puis
    /// transcrit le micro nettoyé + le système. Renvoie nil (repli) si inapplicable ou en cas d'échec.
    private func transcribeWithOfflineAEC(in sessionDir: URL) async -> [TranscriptSegment]? {
        let micURL = sessionDir.appending(path: "\(AudioSource.microphone.rawValue).caf")
        let sysURL = sessionDir.appending(path: "\(AudioSource.system.rawValue).caf")
        func hasAudio(_ url: URL) -> Bool {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
            return FileManager.default.fileExists(atPath: url.path) && (size ?? 0) > 8192
        }
        guard hasAudio(micURL), hasAudio(sysURL) else { return nil }

        let cleanURL = sessionDir.appending(path: "microphone_clean.caf")
        do {
            statusMessage = "Annulation d'écho…"
            AppLog.shared.log("AEC hors-ligne (NLMS) en amont de la transcription…")
            try await Task.detached(priority: .userInitiated) {
                try EchoCancellingProcessor.process(micURL: micURL, referenceURL: sysURL, outputURL: cleanURL)
            }.value
        } catch {
            AppLog.shared.log("AEC hors-ligne échouée : \(AppLog.describe(error)) — repli", level: "WARN")
            return nil
        }

        let locale = Locale(identifier: settings.transcriptionLocaleIdentifier)
        do {
            let mic = try await makeTranscriber().transcribeFile(at: cleanURL, locale: locale).map { seg -> TranscriptSegment in
                var s = seg; s.speakerLabel = "Moi"; return s
            }
            let system = try await makeTranscriber().transcribeFile(at: sysURL, locale: locale).map { seg -> TranscriptSegment in
                var s = seg; s.speakerLabel = "Interlocuteurs"; return s
            }
            // Même backstop textuel que les autres chemins : le NLMS est linéaire, le résidu
            // non-linéaire des HP peut encore se transcrire en doublons.
            let cleanMic = BleedFilter.micWithoutBleed(mic: mic, system: system)
            return (cleanMic + system).sorted { $0.start < $1.start }
        } catch {
            AppLog.shared.log("Transcription post-AEC échouée : \(AppLog.describe(error))", level: "WARN")
            return nil
        }
    }

    /// Transcrit chaque flux présent indépendamment, labellise par source, fusionne par timestamp.
    /// Tolérant : une source qui échoue ou manque est ignorée ; on n'échoue que si aucune n'aboutit.
    private func transcribeSources(in sessionDir: URL) async throws -> [TranscriptSegment] {
        let locale = Locale(identifier: settings.transcriptionLocaleIdentifier)
        let sources: [(AudioSource, String)] = [(.microphone, "Moi"), (.system, "Interlocuteurs")]

        var merged: [TranscriptSegment] = []
        var anyProcessed = false
        var lastError: Error?

        for (source, label) in sources {
            let url = sessionDir.appending(path: "\(source.rawValue).caf")
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
            guard FileManager.default.fileExists(atPath: url.path), (size ?? 0) > 0 else {
                AppLog.shared.log("Source \(source.rawValue) absente ou vide — ignorée")
                continue
            }
            AppLog.shared.log("Transcription \(source.rawValue) (\(label)) : \(size ?? 0) octets, locale \(locale.identifier)…")
            do {
                let segments = try await makeTranscriber().transcribeFile(at: url, locale: locale)
                merged.append(contentsOf: segments.map {
                    var seg = $0; seg.speakerLabel = label; return seg
                })
                anyProcessed = true
                AppLog.shared.log("Transcription \(source.rawValue) OK : \(segments.count) segment(s)")
            } catch {
                lastError = error
                AppLog.shared.log("Transcription \(source.rawValue) échouée : \(AppLog.describe(error))", level: "WARN")
            }
        }

        if !anyProcessed, let lastError { throw lastError }
        // Même dé-duplication du bleed micro que le chemin live.
        let mic = merged.filter { $0.speakerLabel == "Moi" }
        let system = merged.filter { $0.speakerLabel == "Interlocuteurs" }
        let cleanMic = BleedFilter.micWithoutBleed(mic: mic, system: system)
        return (cleanMic + system).sorted { $0.start < $1.start }
    }

    // MARK: - Suivi des actions (Phase 7)

    public var openActions: [ActionItem] {
        ActionTracking.sortedForFollowUp(ActionTracking.openItems(in: actions))
    }

    public func overdueActions(asOf now: Date = Date()) -> [ActionItem] {
        ActionTracking.overdueItems(asOf: now, in: actions)
    }

    private let reminders = RemindersExporter()

    // MARK: - Triage de la boîte mail

    private let mailFetcher = MailFetcher()

    /// Trie la boîte mail des `days` derniers jours : extraction Mail.app → digest → IA → revue
    /// Markdown dans le Vault + actions dans le même suivi que celles des réunions.
    /// L'extraction est longue (~1 min sur une grosse boîte) mais tourne hors du MainActor.
    public func triageMail(days: Int? = nil) async {
        guard !isTriagingMail else { return }
        let period = days ?? settings.mailDays
        guard let provider = provider(), settings.isConfigured else {
            mailStatus = CoordinatorError.notConfigured.errorDescription
            return
        }

        isTriagingMail = true
        mailStatus = "Lecture de Mail (\(period) j) — ça peut prendre une minute…"
        defer { isTriagingMail = false }

        do {
            let fetched = try await mailFetcher.fetch(days: period, limit: settings.mailLimit)
            // Aucun contenu de mail dans les journaux : uniquement des compteurs.
            AppLog.shared.log("Mails extraits : \(fetched.messageCount) messages, \(fetched.threads.count) conversations")
            guard !fetched.threads.isEmpty else {
                mailStatus = "Aucun mail reçu sur cette période."
                return
            }

            mailStatus = "Analyse de \(fetched.threads.count) conversations…"
            let pipeline = MailPipeline(provider: provider, vault: vault())
            let result = try await pipeline.process(
                result: fetched,
                prompt: settings.mailPrompt,
                openActions: Self.openActionsText(Array(openActions.prefix(20))))

            database.saveActions(result.actions)
            database.saveMailReview(result.entries)
            actions = database.loadAllActions()
            mailReviews = database.mailReviews()
            lastMailReviewDate = result.entries.first?.reviewDate
            mailStatus = "\(result.threadCount) conversations triées, \(result.actions.count) action(s)."
            if !result.ignoredIDs.isEmpty {
                AppLog.shared.log("Triage mail : \(result.ignoredIDs.count) id(s) hors limites ignoré(s)", level: "WARN")
            }
        } catch {
            mailStatus = error.localizedDescription
            AppLog.shared.log("Triage mail échoué : \(AppLog.describe(error))", level: "ERROR")
        }
    }

    /// Conversations d'une revue (lues à la sélection, pas à chaque rendu).
    public func mailReview(date: String) -> [MailReviewEntry] {
        database.mailReview(date: date)
    }

    /// Retire une revue de l'historique. Les actions qu'elle a créées restent dans le suivi.
    public func deleteMailReview(date: String) {
        database.deleteMailReview(date: date)
        mailReviews = database.mailReviews()
        if lastMailReviewDate == date { lastMailReviewDate = nil }
    }

    /// Chemin du document Markdown correspondant dans le Vault (affiché en légende).
    public func mailReportPath(date: String) -> String { PathBuilder.mailReportPath(day: date) }

    /// Exporte les actions ouvertes vers Rappels (Phase E). Met à jour `statusMessage` avec le bilan.
    public func exportOpenActionsToReminders() async {
        let n = await reminders.export(openActions)
        statusMessage = n > 0 ? "\(n) action(s) exportée(s) vers Rappels." : "Export Rappels indisponible (accès refusé ?)."
    }

    /// Change le statut d'une action (édition depuis le dashboard de suivi) et le persiste.
    /// Passage obligé de tout changement de statut : c'est ici que les compteurs de revue de mails
    /// (pastille « à traiter » de la barre latérale) sont recalculés.
    public func updateActionStatus(_ id: UUID, to status: ActionStatus) {
        if let i = actions.firstIndex(where: { $0.id == id }) { actions[i].status = status }
        database.updateStatus(id, status)
        mailReviews = database.mailReviews()
    }

    /// Édition manuelle complète d'une action (titre, responsable, échéance, priorité, statut).
    public func updateAction(_ action: ActionItem) {
        if let i = actions.firstIndex(where: { $0.id == action.id }) { actions[i] = action }
        database.saveActions([action])
        updateActionStatus(action.id, to: action.status)   // saveActions préserve volontairement le statut
    }

    /// Édition manuelle d'une réunion (titre, tags, participants) depuis sa fiche.
    public func updateMeeting(_ meeting: Meeting) {
        persist(meeting)
        allTags = database.allTags()
        if currentMeeting?.id == meeting.id { currentMeeting = meeting }
    }

    /// Actions ouvertes de réunions **passées** pertinentes pour la réunion `meeting` : mêmes
    /// participants (via l'owner ou les participants de la réunion d'origine). Sert au pré-brief et
    /// à l'auto-résolution. Bornée pour ne pas gonfler le prompt.
    /// ponytail: overlap simple par nom ; pas de désambiguïsation d'identité (à affiner si besoin).
    private func relevantOpenActions(for meeting: Meeting) -> [ActionItem] {
        let participants = Set(meeting.participants.map { $0.lowercased() })
        let byMeeting = Dictionary(
            meetings.map { ($0.id, Set($0.participants.map { $0.lowercased() })) },
            uniquingKeysWith: { a, _ in a })
        let open = ActionTracking.sortedForFollowUp(ActionTracking.openItems(in: actions))
        let filtered = open.filter { a in
            guard a.meetingID != meeting.id else { return false }        // pas les actions de CETTE réunion
            if participants.isEmpty { return true }                       // participants inconnus → tout (borné)
            if let owner = a.owner, participants.contains(owner.lowercased()) { return true }
            if let mid = a.meetingID, let p = byMeeting[mid], !p.isDisjoint(with: participants) { return true }
            return false
        }
        return Array(filtered.prefix(20))
    }

    private static func openActionsText(_ items: [ActionItem]) -> String {
        items.map { a in
            var s = "- \(a.id.uuidString): \(a.title)"
            if let owner = a.owner, !owner.isEmpty { s += " (@\(owner))" }
            return s
        }.joined(separator: "\n")
    }

    // MARK: - Privé

    enum CoordinatorError: LocalizedError {
        case notConfigured
        case noAudio
        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Configuration IA incomplète — renseigne l'endpoint, le modèle et le token dans les Réglages."
            case .noAudio:
                "Aucun audio à transcrire (dossier d'enregistrement introuvable)."
            }
        }
    }

    private func currentToken() -> String {
        ((try? tokenStore.token(for: tokenAccount)) ?? nil) ?? ""
    }

    private func enabledSources() -> Set<AudioSource> {
        var sources: Set<AudioSource> = []
        if settings.flags.captureMicrophone { sources.insert(.microphone) }
        if settings.flags.captureSystemAudio { sources.insert(.system) }
        return sources.isEmpty ? [.microphone] : sources
    }

    /// Vault courant (repli sur un dossier temporaire si aucun n'est configuré).
    private func vault() -> Vault {
        let root = settings.vaultPath.isEmpty ? NSTemporaryDirectory() : settings.vaultPath
        return Vault(root: URL(fileURLWithPath: root))
    }

    private func provider() -> (any AIProvider)? {
        if let override = makeProviderOverride {
            return override(settings, currentToken())
        }
        return AppCore.makeProvider(settings: settings, token: currentToken())
    }

    private func persist(_ meeting: Meeting) {
        database.save(meeting)
        meetings = database.loadAll()
    }

    static let titleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Étape de traitement en cours, pour la barre de progression de la fenêtre de nommage.
public enum ProcessingPhase: Sendable, Equatable {
    case transcribing
    case analyzing
    case done
    case failed(String)

    public var label: String {
        switch self {
        case .transcribing: "Transcription…"
        case .analyzing: "Analyse IA…"
        case .done: "Terminé"
        case .failed(let m): "Échec — \(m)"
        }
    }

    /// Avancement pour `ProgressView` (nil sur `failed` → barre masquée).
    public var fraction: Double? {
        switch self {
        case .transcribing: 0.33
        case .analyzing: 0.7
        case .done: 1.0
        case .failed: nil
        }
    }

    public var isDone: Bool { self == .done }
    public var isFailed: Bool { if case .failed = self { true } else { false } }
    public var isRunning: Bool { self == .transcribing || self == .analyzing }
}
