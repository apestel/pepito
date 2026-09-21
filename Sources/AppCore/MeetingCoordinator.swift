import Foundation
import Observation
import os
import CaptureKit
import TranscriptionKit
import AIKit
import VaultKit
import ActionKit
import MailKit
import AgentKit

/// Contrôleur applicatif principal (@MainActor, observable) : réglages, enregistrement, et
/// pipeline de bout en bout capture → transcription → analyse agentic. Point d'entrée unique de
/// l'UI. Les dépendances (transcripteur, provider) sont injectables pour tests/previews.
/// Écran affiché dans le volet de détail : le transcript live (pendant un enregistrement), le suivi
/// transverse, une revue de mails, ou une réunion.
public enum SidebarItem: Hashable, Sendable {
    case live
    case dashboard
    case missions
    case mailReview(String)
    case meeting(UUID)
}

@MainActor
@Observable
public final class MeetingCoordinator {
    // Réglages / configuration (Phase 6)
    public let missions: MissionCoordinator
    public var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            if oldValue.missionInternetEnabled != settings.missionInternetEnabled {
                missions.enforceInternetPolicy()
            }
        }
    }
    public var tokenInput: String = ""
    public var tokenPresent: Bool = false
    public var connectionStatus: String?

    // Données (Phase 7)
    public var meetings: [Meeting] = []
    public var actions: [ActionItem] = []
    /// Projets connus (actifs et clos). Le suivi s'organise autour d'eux.
    public var projects: [Project] = []
    /// Tags connus (liste réutilisable), pour le sélecteur de la fenêtre de nommage.
    public var allTags: [String] = []

    /// Notes prises par l'utilisateur pendant la réunion en cours (fenêtre live + nommage). Enrichies
    /// par l'IA (Phase C). Réinitialisées à chaque nouvel enregistrement.
    public var draftNotes: String = ""
    public let instructionDictation: InstructionDictation
    private var instructionMeetingID: UUID?

    /// Pré-brief (Phase D) : actions ouvertes des réunions passées liées aux mêmes participants,
    /// calculées au démarrage d'un enregistrement (« la dernière fois, il restait à… »).
    public var preBrief: [ActionItem] = []

    /// Nombre d'actions de tête du pré-brief issues des occurrences précédentes de la série (le
    /// reste est rattaché par projet/participants). Sert au séparateur de l'encart live.
    public private(set) var preBriefSeriesCount = 0

    /// Triage de la boîte mail : en cours, dernier bilan/erreur, historique des revues (plus
    /// récente en tête) et date de la dernière revue produite (pour la sélectionner dans l'UI).
    public var isTriagingMail: Bool = false
    public var mailStatus: String?
    public var mailReviews: [MailReviewSummary] = []
    public var lastMailReviewDate: String?

    /// Sélection de la barre latérale. Portée par le coordinateur (et non par `MainView`) pour que
    /// n'importe quel écran puisse y naviguer — typiquement une action vers sa réunion d'origine.
    public var selection: SidebarItem = .dashboard

    /// Action en cours de saisie manuelle. Portée ici pour que la barre de menu puisse déclencher la
    /// saisie dans la fenêtre principale : un popover de `MenuBarExtra` se referme, il ne peut pas
    /// héberger la feuille lui-même.
    public var quickCapture: ActionItem?

    /// Ouvre la saisie d'une nouvelle action sur le suivi.
    public func beginQuickCapture(projectID: UUID? = nil, meetingID: UUID? = nil) {
        quickCapture = ActionItem(meetingID: meetingID, projectID: projectID, title: "")
    }

    // État d'exécution
    public var isRecording: Bool = false
    public var isProcessing: Bool = false
    public var statusMessage: String?
    /// Erreur présentée dans toutes les fenêtres ; les éditions non sauvegardées ne sont pas validées.
    public var storageError: String?
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
    /// Nombre de prises de parole conservées par source dans le texte live **affiché**.
    /// Purement cosmétique : le transcript de référence reste l'intégralité des segments finalisés
    /// (`stopLive()`), écrite dans le Vault.
    static let liveDisplaySegmentCap = 200

    /// Transcript live affichable, **une entrée par prise de parole** : les deux sources fusionnées
    /// par ordre chronologique et labellisées (Moi / Interlocuteurs), chaque segment finalisé
    /// valant une pause, l'étiquette n'étant répétée qu'au changement de locuteur.
    ///
    /// Renvoie des lignes séparées, pas un bloc : la vue les empile dans un `LazyVStack` pour que
    /// SwiftUI ne mesure et ne dessine que les lignes visibles. Un `Text` unique obligeait CoreText
    /// à réassembler tout le transcript (shaping + crénage) à chaque passe de rendu — trois fois
    /// par frame (contraintes AppKit, layout SwiftUI, dessin), soit ~80 % de CPU en réunion.
    ///
    /// Plafonné par ailleurs aux `liveDisplaySegmentCap` dernières prises de parole, ce qui borne
    /// aussi `BleedFilter` (O(n·m) sur tout l'historique à chaque hypothèse volatile).
    public var liveTranscriptLines: [String] {
        let cap = Self.liveDisplaySegmentCap
        let recentMic = Array(liveMicSegments.suffix(cap))
        let recentSystem = Array(liveSystemSegments.suffix(cap))
        // Retire le bleed micro (doublons de la sortie HP) aussi en direct.
        let cleanMic = BleedFilter.micWithoutBleed(mic: recentMic, system: recentSystem)
        let labeled = cleanMic.map { ("Moi", $0) } + recentSystem.map { ("Interlocuteurs", $0) }
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
        return lines
    }

    /// Même contenu que `liveTranscriptLines`, en un seul bloc. À ne pas rendre dans un `Text`
    /// unique (voir ci-dessus) : sert au copier-coller et aux tests.
    public var liveTranscriptText: String { liveTranscriptLines.joined(separator: "\n") }

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
        instructionDictation: InstructionDictation? = nil,
        calendar: (any CalendarProviding)? = nil,
        transcriberFactory: @escaping @Sendable () -> any Transcriber = {
            SpeechAnalyzerTranscriber(log: { AppLog.shared.log("Transcription: \($0)") })
        },
        liveTranscriberFactory: @escaping @Sendable (AudioSource) -> any LiveTranscribing = { source in
            SpeechAnalyzerLiveTranscriber(log: { AppLog.shared.log("Live \(source.rawValue): \($0)") })
        },
        providerFactory: (@Sendable (Settings, String) -> (any AIProvider)?)? = nil
    ) {
        self.missions = MissionCoordinator(root: settingsStore.fileURL.deletingLastPathComponent().appending(path: "missions"))
        self.settingsStore = settingsStore
        self.database = database
        self.tokenStore = tokenStore
        self.capture = capture ?? CaptureController(log: { AppLog.shared.log($0) })
        self.instructionDictation = instructionDictation ?? InstructionDictation()
        self.calendar = calendar ?? EventKitCalendar()
        self.makeTranscriber = transcriberFactory
        self.makeLiveTranscriber = liveTranscriberFactory
        self.makeProviderOverride = providerFactory
        self.recordingsRoot = recordingsRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appending(path: "Pepito/recordings")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "Pepito/recordings")

        self.settings = settingsStore.load()
        missions.internetDefault = { [weak self] in self?.settings.missionInternetEnabled ?? true }
        performStorage { try reloadData() }
        self.tokenPresent = ((try? tokenStore.token(for: tokenAccount)) ?? nil) != nil
        missions.sourceProvider = { [weak self] mission in try self?.missionSources(mission) ?? [] }
        missions.sourceReader = { [weak self] id, mission in
            guard let self, id.hasPrefix("meeting:"), let meetingID=UUID(uuidString:String(id.dropFirst(8))),
                  mission.includePepito || mission.meetingID == meetingID,
                  let meeting=try database.loadMeeting(meetingID) else { return nil }
            return MissionSource(id:id,kind:"meeting",title:meeting.title,text:meeting.transcript ?? "Transcript indisponible",url:location(for:meeting)?.absoluteString)
        }
        missions.actionProvider = { [weak self] id in self?.actions.first { $0.id == id } }
        missions.applyAction = { [weak self] old, status in
            guard let self else { throw AgentError.unavailable("Stockage indisponible") }
            try database.transaction {
                guard try database.loadAllActions().first(where: { $0.id == old.id }) == old else {
                    throw AgentError.unavailable("L’action a changé depuis la proposition.")
                }
                try database.updateStatus(old.id, status)
            }
            try reloadData()
        }
    }

    // MARK: - Réglages

    /// Persiste immédiatement pour que quitter ou reconstruire l'app ne perde aucune édition.
    @discardableResult
    public func saveSettings() -> Bool {
        performStorage { try settingsStore.save(settings) }
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
        guard !isRecording, !instructionDictation.isActive else { return }
        guard saveSummaryInstructions(for: instructionMeetingID) else { return }
        instructionMeetingID = nil
        instructionDictation.text = ""
        let started = Date()
        let tempTitle = Meeting.autoTitlePrefix + Self.titleDateFormatter.string(from: started)
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
        let title = (event?.title.isEmpty == false) ? event!.title : tempTitle
        let meeting = Meeting(
            title: title,
            startedAt: started,
            participants: event?.participants ?? [],
            status: .recording,
            // Projet deviné dès le départ depuis le titre de l'événement : c'est ce qui rend le
            // pré-brief pertinent, alors que les tags n'arrivent qu'à l'arrêt.
            projectID: matchProject(named: title)?.id,
            sessionDirPath: sessionDir.path
        )
        currentMeeting = meeting
        currentSessionDir = sessionDir
        refreshPreBrief(for: meeting)   // « la dernière fois, il restait à… »
        isRecording = true
        let saved = performStorage { try persist(meeting) }
        syncLevelSampling()   // ne démarre la FFT que si une vue affiche les niveaux

        guard saved else { return }
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
        instructionMeetingID = meeting.id
        instructionDictation.text = meeting.summaryInstructions ?? ""
        currentMeeting = meeting
        isStopping = false
        guard performStorage({ try persist(meeting) }) else { return }
        statusMessage = "En attente de nom…"
    }

    /// Nomme la réunion arrêtée, enregistre ses tags, puis lance le pipeline complet.
    public func nameAndProcess(title: String, tags: [String]) async {
        guard !isRecording, !isProcessing else { return }
        let id = currentMeeting?.id
        await instructionDictation.stop()
        guard currentMeeting?.id == id else { return }
        guard var meeting = currentMeeting, !isProcessing else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = trimmed.isEmpty ? meeting.title : trimmed
        let cleanTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        meeting.title = cleanTitle
        meeting.tags = cleanTags
        if instructionMeetingID == meeting.id { meeting.summaryInstructions = instructionDictation.text }
        currentMeeting = meeting
        await runPipeline(meeting)
    }

    /// Reprend une réunion interrompue (échec d'une étape). Réutilise le transcript persisté pour
    /// éviter de re-transcrire ; ré-exécute à partir de l'étape appropriée.
    public func resume(_ meeting: Meeting) async {
        guard meeting.status.isResumable, !isProcessing, !isRecording, !instructionDictation.isActive else { return }
        var meeting = meeting
        guard performStorage({ meeting = try database.loadMeeting(meeting.id) ?? meeting }) else { return }
        currentMeeting = meeting
        currentSessionDir = meeting.sessionDirPath.map { URL(fileURLWithPath: $0) }
        AppLog.shared.log("Reprise du traitement : « \(meeting.title) » (étape \(meeting.status.rawValue))")
        await runPipeline(meeting)
    }

    /// Runner d'étapes : transcription → analyse IA (+ écriture Vault). Persiste `status` à chaque
    /// étape ; un échec laisse la réunion reprenable (`lastError` renseigné, `status` sur l'étape).
    private func runPipeline(_ meetingIn: Meeting) async {
        var meeting = meetingIn
        if meeting.folderPath.isEmpty {
            meeting.folderPath = PathBuilder.meetingFolder(
                date: meeting.startedAt, title: meeting.title, meetingID: meeting.id)
        }
        isProcessing = true
        meeting.lastError = nil

        // 1. Transcription (instantanée si le live a produit ; sinon fichiers / AEC hors-ligne).
        let transcript: String
        do {
            processingPhase = .transcribing
            meeting.status = .transcribing
            statusMessage = "Transcription…"
            try persist(meeting)
            transcript = try await resolveTranscript(for: meeting)
            meeting.transcript = transcript
            AppLog.shared.log("Transcription OK : \(transcript.count) car.")
            try persist(meeting) // conserver le transcript même si le Vault est indisponible
            try writeTranscriptToVault(transcript, folder: meeting.folderPath)
            if let instructions = meeting.summaryInstructions {
                try vault().write(VaultDocument(
                    relativePath: PathBuilder.instructionsPath(meetingFolder: meeting.folderPath),
                    type: .meetingNote,
                    markdown: instructions))
            }
        } catch {
            fail(&meeting, phase: "Transcription", error: error)
            return
        }

        // 2. Analyse IA (le pipeline écrit aussi résumé + plan d'action dans le Vault).
        do {
            processingPhase = .analyzing
            meeting.status = .processing
            statusMessage = "Analyse IA…"
            try persist(meeting)
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
                openActions: Self.openActionsText(followUp),
                projects: projects,
                userName: settings.userName,
                existingActions: try database.loadAllActions().filter { $0.meetingID == meeting.id },
                inputTokenBudget: settings.aiInputTokenBudget
            )
            var completed = meeting
            completed.status = .done
            try database.transaction {
                let latest = try database.loadAllActions()
                try database.saveActions(result.actions)
                // Les écritures liées réussissent ou sont toutes annulées.
                for update in result.actionUpdates {
                    // Aucun suivi de CETTE réunion ne doit être réinitialisé par le retraitement.
                    // Une édition survenue pendant la requête garde également la priorité.
                    guard let original = followUp.first(where: { $0.id == update.id }),
                          latest.first(where: { $0.id == update.id })?.status == original.status else { continue }
                    try database.updateStatus(update.id, update.status)
                }
                try database.save(completed)
            }
            try reloadData()
            meeting = completed
            processingPhase = .done
            statusMessage = "Terminé — \(result.actions.count) action(s)."
            AppLog.shared.log("Analyse OK : \(result.actions.count) action(s), \(result.documentsWritten.count) document(s)")
        } catch {
            fail(&meeting, phase: "Analyse IA", error: error)
            return
        }

        currentMeeting = meeting   // conservé pour « Ouvrir l'emplacement » depuis la fenêtre de nommage
        isProcessing = false
    }

    /// Réunion en cours de nommage/traitement (pour la fenêtre de nommage).
    public var pendingMeeting: Meeting? { currentMeeting }

    // MARK: - Projet & tags pendant la réunion

    /// Projet de la réunion en cours. Modifiable en direct : c'est ce qui rend le pré-brief
    /// pertinent sans attendre la fenêtre de nommage.
    public var currentProjectID: UUID? { currentMeeting?.projectID }
    public var currentTags: [String] { currentMeeting?.tags ?? [] }

    public func setCurrentProject(_ id: UUID?) {
        guard var meeting = currentMeeting else { return }
        meeting.projectID = id
        guard performStorage({ try persist(meeting) }) else { return }
        currentMeeting = meeting
        refreshPreBrief(for: meeting)   // recentré sur le projet, tout de suite
    }

    public func toggleCurrentTag(_ tag: String) {
        guard var meeting = currentMeeting else { return }
        if let i = meeting.tags.firstIndex(of: tag) { meeting.tags.remove(at: i) }
        else { meeting.tags.append(tag) }
        guard performStorage({ try persist(meeting) }) else { return }
        currentMeeting = meeting
    }

    /// Relance le pipeline sur la réunion en cours (bouton « Réessayer » après un échec).
    public func retryProcessing() async {
        guard !isRecording, !isProcessing else { return }
        let id = currentMeeting?.id
        await instructionDictation.stop()
        guard var meeting = currentMeeting, meeting.id == id, !isProcessing else { return }
        if instructionMeetingID == meeting.id { meeting.summaryInstructions = instructionDictation.text }
        await runPipeline(meeting)
    }

    /// Prépare la reprise d'une réunion depuis la timeline : la fenêtre de nommage l'affiche (formulaire
    /// si elle n'est pas nommée, sinon état d'échec avec « Réessayer »).
    public func setPending(_ meeting: Meeting) {
        guard !instructionDictation.isActive, !isRecording, !isProcessing else { return }
        guard saveSummaryInstructions(for: instructionMeetingID) else { return }
        var meeting = meeting
        guard performStorage({ meeting = try database.loadMeeting(meeting.id) ?? meeting }) else { return }
        instructionMeetingID = meeting.id
        instructionDictation.text = meeting.summaryInstructions ?? ""
        draftNotes = meeting.userNotes
        currentMeeting = meeting
        currentSessionDir = meeting.sessionDirPath.map { URL(fileURLWithPath: $0) }
        processingPhase = meeting.lastError.map { .failed($0) }
    }

    /// Démarrage explicite depuis la fenêtre de fin de réunion, sans capture système.
    public func startInstructionDictation() {
        guard currentMeeting?.id == instructionMeetingID, instructionMeetingID != nil,
              !isRecording, !isProcessing else { return }
        instructionDictation.start(locale: Locale(identifier: settings.transcriptionLocaleIdentifier))
    }

    /// Sauvegarde du brouillon sans confondre deux réunions lors d'une fermeture/changement de sélection.
    @discardableResult
    public func saveSummaryInstructions(for id: UUID?) -> Bool {
        guard !isRecording, !isProcessing else { return true }
        guard let id, instructionMeetingID == id, var meeting = currentMeeting, meeting.id == id else { return true }
        guard meeting.summaryInstructions != instructionDictation.text else { return true }
        meeting.summaryInstructions = instructionDictation.text
        guard performStorage({ try persist(meeting) }) else { return false }
        currentMeeting = meeting
        return true
    }

    public func finishInstructionEditing(for id: UUID?) async {
        guard instructionMeetingID == id else { return }
        await instructionDictation.stop()
        saveSummaryInstructions(for: id)
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

    /// Une écriture manquante bloque le traitement, dont le transcript reste conservé en base.
    private func writeTranscriptToVault(_ transcript: String, folder: String) throws {
        guard !settings.vaultPath.isEmpty else { throw CoordinatorError.notConfigured }
        try vault().write(VaultDocument(
            relativePath: PathBuilder.transcriptPath(meetingFolder: folder),
            type: .meetingNote,
            markdown: transcript
        ))
    }

    /// URL du dossier de la réunion dans le Vault (pour « Ouvrir l'emplacement »), sinon dossier audio.
    /// Supprime une réunion : documents du Vault, fichiers audio, et lignes en base (actions + tags
    /// en cascade). Action **destructive** — l'UI confirme avant d'appeler.
    public func deleteMeeting(_ meeting: Meeting) {
        // Ne pas supprimer la réunion en cours d'enregistrement/traitement.
        guard !(currentMeeting?.id == meeting.id && (isRecording || isProcessing)) else { return }

        guard performStorage({ try database.delete(meeting.id) }) else { return }
        // Les anciens dossiers peuvent être partagés : ne pas effacer les documents d'une autre réunion.
        if !settings.vaultPath.isEmpty, !meeting.folderPath.isEmpty,
           !meetings.contains(where: { $0.id != meeting.id && $0.folderPath == meeting.folderPath }) {
            let folder = URL(fileURLWithPath: settings.vaultPath).appending(path: meeting.folderPath)
            if FileManager.default.fileExists(atPath: folder.path) {
                performStorage { try FileManager.default.removeItem(at: folder) }
            }
        }
        if let dir = meeting.sessionDirPath, FileManager.default.fileExists(atPath: dir) {
            performStorage { try FileManager.default.removeItem(at: URL(fileURLWithPath: dir)) }
        }
        if currentMeeting?.id == meeting.id { currentMeeting = nil }
        performStorage { try reloadData() }
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

    /// Vrai tant qu'une vue affiche les niveaux (la vue « En direct », seul consommateur
    /// de `micSpectrogram`/`systemSpectrogram`). La vue le bascule via `onAppear`/`onDisappear`.
    ///
    /// Sans consommateur à l'écran, ni la FFT ni les mutations observables à 30 Hz ne servent —
    /// et ces dernières coûtent plus cher que la FFT, puisque chacune invalide un graphe SwiftUI.
    public var levelsVisible = false {
        didSet { syncLevelSampling() }
    }

    /// Vrai quand la boucle d'échantillonnage tourne. Les niveaux ne sont calculés que pendant un
    /// enregistrement **et** quand une vue les affiche.
    var isSamplingLevels: Bool { levelTask != nil }

    /// Démarre ou arrête la boucle selon l'état courant. Appelée à chaque changement des deux
    /// conditions (`isRecording`, `levelsVisible`) — idempotente.
    private func syncLevelSampling() {
        switch (isRecording && levelsVisible, levelTask) {
        case (true, nil): startLevelSampling()
        case (false, .some(let task)):
            task.cancel()
            levelTask = nil
            micSpectrogram = []
            systemSpectrogram = []
        default: break
        }
    }

    /// Échantillonne le spectre à ~30 Hz et pousse une colonne dans les spectrogrammes roulants.
    /// La FFT tourne sur un thread de fond (`Task.detached`) pour ne pas partager le MainActor avec
    /// l'arrivée des résultats de transcription : sinon un burst de transcript fige le spectre (et
    /// vice-versa). On ne repasse sur le MainActor que pour publier les colonnes calculées.
    ///
    /// `SpectrumMeter.push` continue de tourner sur le thread audio même quand rien n'affiche :
    /// c'est une copie dans une fenêtre glissante, pas un calcul, et elle garantit un spectre
    /// immédiat à l'ouverture du popover plutôt que 4,6 s de colonnes vides.
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
        performStorage { try persist(meeting) }
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
        ActionTracking.sortedForFollowUp(ActionTracking.overdueItems(asOf: now, in: actions))
    }

    /// Implication effective d'une action : surcharge manuelle, sinon déduite du responsable via les
    /// réglages « moi » / « mon équipe ».
    public func involvement(of action: ActionItem) -> Involvement {
        action.resolvedInvolvement(me: settings.userName, team: settings.teamMembers)
    }

    /// Actions ouvertes d'une catégorie d'implication. Les retards sont exclus par défaut : ils ont
    /// leur propre section en tête du suivi, les lister deux fois n'aide personne.
    public func openActions(
        for involvement: Involvement, excludingOverdue: Bool = true, asOf now: Date = Date()
    ) -> [ActionItem] {
        let overdue = excludingOverdue ? Set(overdueActions(asOf: now).map(\.id)) : []
        return openActions.filter {
            self.involvement(of: $0) == involvement && !overdue.contains($0.id)
        }
    }

    /// Actions d'une même catégorie réparties par projet : projets connus d'abord (ordre de
    /// `projects`), « Sans projet » en dernier.
    public func groupedByProject(_ items: [ActionItem]) -> [ProjectGroup] {
        let buckets = Dictionary(grouping: items, by: \.projectID)
        var groups = projects.compactMap { p in
            buckets[p.id].map { ProjectGroup(project: p, actions: $0) }
        }
        if let orphans = buckets[nil] { groups.append(ProjectGroup(project: nil, actions: orphans)) }
        return groups
    }

    public var activeProjects: [Project] { projects.filter { $0.status == .active } }

    public func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public func meeting(_ id: UUID?) -> Meeting? {
        guard let id else { return nil }
        return meetings.first { $0.id == id }
    }

    /// Réunions de la barre latérale, les récurrentes regroupées sous leur titre. `meetings` arrive
    /// déjà en `started_at DESC` : l'ordre chronologique décroissant est conservé dans chaque groupe
    /// comme entre les groupes (un groupe se classe à la date de son occurrence la plus récente).
    public var meetingSeries: [MeetingSeries] {
        var order: [String] = []
        var byKey: [String: [Meeting]] = [:]
        for meeting in meetings {
            let key = meeting.seriesKey
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(meeting)
        }
        return order.map { MeetingSeries(key: $0, meetings: byKey[$0] ?? []) }
    }

    /// Projet dont le nom se rapproche le plus d'un texte libre (titre d'événement calendrier, nom
    /// renvoyé par l'IA) : correspondance exacte, sinon nom de projet contenu dans le texte.
    public func matchProject(named text: String) -> Project? {
        let key = Project.matchKey(text)
        guard !key.isEmpty else { return nil }
        if let exact = activeProjects.first(where: { Project.matchKey($0.name) == key }) { return exact }
        // Le plus long nom gagne : « Migration SI RH » l'emporte sur « Migration SI ».
        return activeProjects
            .filter { !Project.matchKey($0.name).isEmpty && key.contains(Project.matchKey($0.name)) }
            .max { Project.matchKey($0.name).count < Project.matchKey($1.name).count }
    }

    // MARK: - Édition des actions

    /// Crée une action à la main (suivi, fiche réunion, barre de menu) — le seul chemin de naissance
    /// hors pipelines IA.
    public func addAction(_ action: ActionItem) {
        guard performStorage({ try database.saveActions([action]) }) else { return }
        actions.append(action)
    }

    /// Pose ou retire la surcharge d'implication (`nil` = revenir à la déduction automatique).
    public func setInvolvement(_ id: UUID, to involvement: Involvement?) {
        guard performStorage({ try database.updateInvolvement(id, involvement) }) else { return }
        if let i = actions.firstIndex(where: { $0.id == id }) { actions[i].involvement = involvement }
    }

    // MARK: - Projets

    public func saveProject(_ project: Project) {
        performStorage {
            try database.saveProject(project)
            projects = try database.loadProjects()
        }
    }

    /// Supprime un projet. Ses actions restent dans le suivi, simplement non classées.
    public func deleteProject(_ id: UUID) {
        performStorage {
            try database.deleteProject(id)
            try reloadData()
        }
    }

    private let reminders = RemindersExporter()

    // MARK: - Triage de la boîte mail

    private let mailFetcher = MailFetcher()

    /// Trie la boîte mail sur la période demandée (jours calendaires) : extraction Mail.app →
    /// digest → IA → revue Markdown dans le Vault + actions dans le même suivi que celles des
    /// réunions. La revue est identifiée par sa période : retrier la même la remplace, trier une
    /// autre période crée une nouvelle entrée d'historique.
    /// L'extraction est longue (~1 min sur une grosse boîte) mais tourne hors du MainActor.
    public func triageMail(period: MailPeriod) async {
        guard !isTriagingMail else { return }
        guard let provider = provider(), settings.isConfigured else {
            mailStatus = CoordinatorError.notConfigured.errorDescription
            return
        }

        isTriagingMail = true
        mailStatus = "Lecture de Mail (\(period.label)) — ça peut prendre une minute…"
        defer { isTriagingMail = false }

        do {
            let fetched = try await mailFetcher.fetch(period: period, limit: settings.mailLimit)
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

            try database.transaction {
                try database.saveActions(result.actions)
                try database.saveMailReview(result.entries)
            }
            try reloadData()
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

    /// Conversations d'une revue, par clé de période (lues à la sélection, pas à chaque rendu).
    public func mailReview(date: String) -> [MailReviewEntry] {
        do { return try database.mailReview(date: date) }
        catch { reportStorageError(error); return [] }
    }

    /// Retire une revue de l'historique. Les actions qu'elle a créées restent dans le suivi.
    public func deleteMailReview(date: String) {
        performStorage {
            try database.deleteMailReview(date: date)
            mailReviews = try database.mailReviews()
            if lastMailReviewDate == date { lastMailReviewDate = nil }
        }
    }

    /// Chemin du document Markdown correspondant dans le Vault (affiché en légende).
    public func mailReportPath(date: String) -> String { PathBuilder.mailReportPath(periodKey: date) }

    /// Exporte les actions ouvertes vers Rappels (Phase E). Met à jour `statusMessage` avec le bilan.
    public func exportOpenActionsToReminders() async {
        let n = await reminders.export(openActions)
        statusMessage = n > 0 ? "\(n) action(s) exportée(s) vers Rappels." : "Export Rappels indisponible (accès refusé ?)."
    }

    /// Change le statut d'une action (édition depuis le dashboard de suivi) et le persiste.
    /// Passage obligé de tout changement de statut : c'est ici que les compteurs de revue de mails
    /// (pastille « à traiter » de la barre latérale) sont recalculés.
    public func updateActionStatus(_ id: UUID, to status: ActionStatus) {
        guard performStorage({ try database.updateStatus(id, status) }) else { return }
        if let i = actions.firstIndex(where: { $0.id == id }) { actions[i].status = status }
        performStorage { mailReviews = try database.mailReviews() }
    }

    /// Édition manuelle : tous les champs sont sauvegardés ensemble, avant de changer l'interface.
    public func updateAction(_ action: ActionItem) {
        guard performStorage({
            try database.transaction {
                try database.saveActions([action])
                try database.updateInvolvement(action.id, action.involvement)
                try database.updateStatus(action.id, action.status)
            }
        }) else { return }
        if let i = actions.firstIndex(where: { $0.id == action.id }) { actions[i] = action }
        performStorage { mailReviews = try database.mailReviews() }
    }

    /// Édition manuelle d'une réunion (titre, tags, participants) depuis sa fiche.
    public func updateMeeting(_ meeting: Meeting) {
        var updated = meeting
        guard performStorage({
            // Une ligne de timeline ne porte pas le transcript. L'édition de métadonnées ne
            // doit jamais effacer le contenu ni l'état de traitement sauvegardés.
            if var stored = try database.loadMeeting(meeting.id) {
                stored.title = meeting.title
                stored.participants = meeting.participants
                stored.tags = meeting.tags
                stored.projectID = meeting.projectID
                updated = stored
            }
            try persist(updated)
        }) else { return }
        if currentMeeting?.id == updated.id { currentMeeting = updated }
    }

    /// Actions ouvertes de réunions **passées** pertinentes pour `meeting`. Sert au pré-brief et à
    /// l'auto-résolution ; bornée pour ne pas gonfler le prompt.
    ///
    /// Score plutôt que filtre binaire : le projet de la réunion prime (seul critère disponible dès
    /// le démarrage, avant le nommage), puis le responsable, puis le recoupement de participants.
    /// Sans projet renseigné on retrouve exactement l'ancien comportement.
    /// ponytail: overlap simple par nom ; pas de désambiguïsation d'identité (à affiner si besoin).
    /// Occurrences précédentes de la même réunion récurrente : leur reste-à-faire est le rappel
    /// le plus attendu au démarrage (« la dernière fois, il restait à… »).
    func seriesMeetingIDs(for meeting: Meeting) -> Set<UUID> {
        let key = meeting.seriesKey
        // La réunion en cours est déjà en base (`persist`) quand on recalcule : elle s'exclut.
        return Set(meetings.filter { $0.id != meeting.id && $0.seriesKey == key }.map(\.id))
    }

    /// Recalcule le pré-brief et la taille de son bloc « série » (préfixe contigu, la série
    /// dominant le score).
    private func refreshPreBrief(for meeting: Meeting) {
        preBrief = relevantOpenActions(for: meeting)
        let series = seriesMeetingIDs(for: meeting)
        preBriefSeriesCount = preBrief.prefix { $0.meetingID.map(series.contains) == true }.count
    }

    func relevantOpenActions(for meeting: Meeting) -> [ActionItem] {
        let participants = Set(meeting.participants.map { $0.lowercased() })
        let series = seriesMeetingIDs(for: meeting)
        let byMeeting = Dictionary(
            meetings.map { ($0.id, Set($0.participants.map { $0.lowercased() })) },
            uniquingKeysWith: { a, _ in a })

        func score(_ a: ActionItem) -> Int {
            var score = 0
            // 20 > 10+5+2 : ce qui vient de la série passe devant tout le reste.
            if let mid = a.meetingID, series.contains(mid) { score += 20 }
            if let project = meeting.projectID, a.projectID == project { score += 10 }
            if let owner = a.owner, participants.contains(owner.lowercased()) { score += 5 }
            if let mid = a.meetingID, let p = byMeeting[mid], !p.isDisjoint(with: participants) { score += 2 }
            // Ce que je ne porte ni ne suis n'a rien à faire dans un pré-brief.
            if involvement(of: a) == .info { score -= 3 }
            return score
        }

        let open = ActionTracking.sortedForFollowUp(ActionTracking.openItems(in: actions))
            .filter { $0.meetingID != meeting.id }   // pas les actions de CETTE réunion
        let scored = open.map { (item: $0, score: score($0)) }
        // Rien de rattachable (réunion sans projet ni participants connus) : on garde la liste
        // triée par urgence plutôt que de n'afficher aucun rappel.
        let relevant = scored.contains { $0.score > 0 } ? scored.filter { $0.score > 0 } : scored
        // `sorted` est stable : à score égal, l'ordre de suivi (priorité, échéance) est conservé.
        return Array(relevant.sorted { $0.score > $1.score }.map(\.item).prefix(20))
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

    private func persist(_ meeting: Meeting) throws {
        try database.save(meeting)
        let tags = try database.allTags()
        var summary = meeting
        summary.transcript = nil
        summary.tags = Array(Set(summary.tags.filter { !$0.isEmpty })).sorted()
        if let index = meetings.firstIndex(where: { $0.id == summary.id }) {
            meetings[index] = summary
        } else {
            meetings.append(summary)
        }
        meetings.sort { $0.startedAt > $1.startedAt }
        allTags = tags
    }

    /// Ne remplace pas les données affichées par des tableaux vides si une lecture échoue.
    private func reloadData() throws {
        let loadedMeetings = try database.loadAll(includeTranscripts: false)
        let loadedActions = try database.loadAllActions()
        let loadedProjects = try database.loadProjects()
        let tags = try database.allTags()
        let reviews = try database.mailReviews()
        meetings = loadedMeetings
        actions = loadedActions
        projects = loadedProjects
        allTags = tags
        mailReviews = reviews
    }

    @discardableResult
    private func performStorage(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return true }
        catch { reportStorageError(error); return false }
    }

    private func reportStorageError(_ error: Error) {
        let message = "Échec du stockage : \(error.localizedDescription)"
        storageError = message
        statusMessage = message
        AppLog.shared.log(message, level: "ERROR")
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


extension MeetingCoordinator {
    public func beginMission(meeting: Meeting? = nil) {
        missions.create(meeting: meeting); selection = .missions
    }
    public func sendMission(probe: Bool = false) {
        missions.send(settings: settings, token: currentToken(), probe: probe)
    }
    private func missionSources(_ mission: Mission) throws -> [MissionSource] {
        var result: [MissionSource] = []
        let selectedMeetings = mission.includePepito ? meetings : meetings.filter { $0.id == mission.meetingID }
        for m in selectedMeetings {
            result.append(MissionSource(id: "meeting:" + m.id.uuidString, kind: "meeting", title: m.title,
                text: String((summaryMarkdown(for: m) ?? "Résumé indisponible. read_source donne accès au transcript.").prefix(6000)), url: location(for: m)?.absoluteString))
        }
        for a in actions where mission.includePepito || (mission.meetingID != nil && a.meetingID == mission.meetingID) {
            result.append(MissionSource(id: "action:" + a.id.uuidString, kind: "action", title: a.title,
                text: "Statut: \(a.status.rawValue)\nResponsable: \(a.owner ?? "")\nÉchéance: \(a.dueDate?.description ?? "")\n\(a.details)", url: a.sourceURL))
        }
        if mission.includePepito {
            for review in mailReviews {
                for entry in try database.mailReview(date: review.date) {
                    result.append(MissionSource(id: "mail:" + entry.id, kind: "mail", title: entry.subject,
                        text: "\(entry.sender)\n\(entry.summary)\nAction: \(entry.action)\n\(entry.why)", url: entry.url))
                }
            }
        }
        return result
    }
}
