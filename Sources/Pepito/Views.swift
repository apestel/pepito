import SwiftUI
import AppCore
import CaptureKit

// MARK: - Menu bar

struct MenuBarContent: View {
    @Bindable var app: MeetingCoordinator
    @Environment(\.openWindow) private var openWindow

    /// Ouvre une fenêtre en amenant l'app au premier plan (sinon elle s'ouvre derrière).
    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pépito").font(.headline)

            if app.isRecording {
                RecordingLevelsView(mic: app.micSpectrogram, system: app.systemSpectrogram)
                Button(role: .destructive) {
                    // À l'arrêt, la saisie du nom + tags se fait dans la fenêtre dédiée.
                    Task { await app.stopRecording(); open("naming") }
                } label: {
                    Label("Arrêter", systemImage: "stop.circle.fill")
                }
            } else {
                Button {
                    Task { await app.startRecording() }
                } label: {
                    Label("Démarrer l'enregistrement", systemImage: "record.circle")
                }
                .disabled(app.isProcessing)
            }

            if let status = app.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if !app.settings.isConfigured {
                Label("Configuration incomplète (Réglages)", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Button { open("live") } label: {
                Label("Transcript en direct", systemImage: "waveform.badge.mic")
            }

            Divider()
            Button { open("settings") } label: { Label("Réglages…", systemImage: "gearshape") }
            Button("Quitter") { NSApplication.shared.terminate(nil) }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Visualisation des niveaux (live)

/// Spectrogramme live (FFT) : temps en X, fréquence en Y. Superpose les deux sources — micro
/// (« Moi ») en bleu, système (« Interlocuteurs ») en orange — chaque source colorant les cellules
/// selon sa magnitude, le chevauchement se mélangeant à l'écran.
struct RecordingLevelsView: View {
    let mic: [[Float]]
    let system: [[Float]]

    var body: some View {
        Canvas { ctx, size in
            heatmap(mic, in: ctx, size: size, color: .blue)
            heatmap(system, in: ctx, size: size, color: .orange)
        }
        .frame(height: 90)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 10) {
                Label("Moi", systemImage: "circle.fill").foregroundStyle(.blue)
                Label("Interlocuteurs", systemImage: "circle.fill").foregroundStyle(.orange)
            }
            .font(.system(size: 9)).labelStyle(.titleAndIcon).padding(4)
        }
    }

    // ponytail: fill par cellule avec seuil ; si ça rame, passer à un CGImage tracé en une fois.
    private func heatmap(_ columns: [[Float]], in ctx: GraphicsContext, size: CGSize, color: Color) {
        guard !columns.isEmpty else { return }
        let colW = size.width / CGFloat(columns.count)
        for (i, column) in columns.enumerated() {
            guard !column.isEmpty else { continue }
            let bandH = size.height / CGFloat(column.count)
            let x = CGFloat(i) * colW
            for (j, v) in column.enumerated() where v > 0.06 {
                // Basses fréquences en bas.
                let y = size.height - CGFloat(j + 1) * bandH
                ctx.fill(
                    Path(CGRect(x: x, y: y, width: colW + 0.5, height: bandH + 0.5)),
                    with: .color(color.opacity(Double(min(1, v))))
                )
            }
        }
    }
}

// MARK: - Fenêtre principale

struct MainView: View {
    @Bindable var app: MeetingCoordinator
    @State private var selection: Meeting.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Réunions") {
                    if app.meetings.isEmpty {
                        Text("Aucune réunion").foregroundStyle(.secondary)
                    }
                    ForEach(app.meetings) { meeting in
                        MeetingRow(meeting: meeting).tag(meeting.id)
                    }
                }
            }
            .navigationTitle("Pépito")
            .frame(minWidth: 240)
        } detail: {
            if let id = selection, let meeting = app.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(app: app, meeting: meeting)
            } else {
                DashboardView(app: app)
            }
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(meeting.title).font(.body)
                Text(meeting.startedAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: meeting.status)
        }
    }
}

struct StatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .recording: "enreg."
        case .awaitingName: "à nommer"
        case .transcribing: "transcript."
        case .processing: "analyse"
        case .done: "terminé"
        }
    }
    private var color: Color {
        switch status {
        case .recording: .red
        case .awaitingName: .blue
        case .transcribing, .processing: .orange
        case .done: .green
        }
    }
}

struct MeetingDetailView: View {
    @Bindable var app: MeetingCoordinator
    @Environment(\.openWindow) private var openWindow
    let meeting: Meeting

    private var meetingActions: [ActionItem] {
        app.actions.filter { $0.meetingID == meeting.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(meeting.title).font(.largeTitle.bold())
                    StatusBadge(status: meeting.status)
                }
                if !meeting.participants.isEmpty {
                    Label(meeting.participants.joined(separator: ", "), systemImage: "person.2")
                        .foregroundStyle(.secondary)
                }
                if !meeting.tags.isEmpty {
                    Label(meeting.tags.joined(separator: ", "), systemImage: "tag")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Label(meeting.folderPath.isEmpty ? "(non rangée)" : meeting.folderPath, systemImage: "folder")
                    .font(.callout).foregroundStyle(.secondary)

                // Réunion interrompue (échec d'étape ou non nommée) : reprise possible.
                if meeting.status == .awaitingName || meeting.lastError != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            app.setPending(meeting)
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "naming")
                        } label: {
                            Label(
                                meeting.status == .awaitingName ? "Nommer & analyser" : "Reprendre le traitement",
                                systemImage: "arrow.clockwise")
                        }
                        if let err = meeting.lastError {
                            Text(err).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }

                GroupBox("Plans d'action (\(meetingActions.count))") {
                    if meetingActions.isEmpty {
                        Text("Aucune action extraite").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(meetingActions) { action in
                            ActionRow(action: action)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ActionRow: View {
    let action: ActionItem

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: action.status == .done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(action.status == .done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                HStack(spacing: 8) {
                    if let owner = action.owner {
                        Label(owner, systemImage: "person").font(.caption)
                    }
                    if let due = action.dueDate {
                        Label(due.formatted(.dateTime.day().month()), systemImage: "calendar").font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

/// Tableau de bord de suivi (Phase 7) : actions ouvertes et en retard, transverses aux réunions.
struct DashboardView: View {
    @Bindable var app: MeetingCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Suivi").font(.largeTitle.bold())

                let overdue = app.overdueActions()
                if !overdue.isEmpty {
                    GroupBox("En retard (\(overdue.count))") {
                        ForEach(overdue) { ActionRow(action: $0) }
                    }
                }

                GroupBox("Actions ouvertes (\(app.openActions.count))") {
                    if app.openActions.isEmpty {
                        Text("Rien à suivre pour l'instant").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(app.openActions) { ActionRow(action: $0) }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Transcript en direct

struct LiveTranscriptView: View {
    @Bindable var app: MeetingCoordinator

    var body: some View {
        // Calculé une seule fois par rendu (propriété coûteuse : bleed-filter + tri de tout
        // l'historique). Trois lectures = trois recalculs à chaque hypothèse volatile.
        let live = app.liveTranscriptText
        let display = live.isEmpty
            ? (app.isRecording ? "En attente de parole…" : "Démarre un enregistrement pour voir le transcript en direct.")
            : live
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: app.isRecording ? "waveform" : "waveform.slash")
                    .foregroundStyle(app.isRecording ? .red : .secondary)
                    .symbolEffect(.variableColor, isActive: app.isRecording)
                Text(app.isRecording ? "En direct" : "Aucun enregistrement")
                    .font(.headline)
                Spacer()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(display)
                        .font(.body)
                        .foregroundStyle(live.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: live) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .padding()
        .frame(minWidth: 380, minHeight: 260)
    }
}

// MARK: - Fenêtre de nommage (après arrêt)

/// Ouverte à l'arrêt d'un enregistrement : saisie du nom + tags, puis « Valider » lance le pipeline
/// avec une barre de progression. En fin, propose d'ouvrir l'emplacement ou de fermer.
struct NamingView: View {
    @Bindable var app: MeetingCoordinator
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var title = ""
    @State private var selectedTags: Set<String> = []
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(header).font(.headline)

            if let phase = app.processingPhase {
                if phase.isFailed { failureSection(phase) } else { progressSection(phase) }
            } else {
                formSection
            }
        }
        .padding(20)
        .frame(width: 440)
        // Pré-remplit à l'ouverture. Un titre temporaire (« Réunion du … ») laisse le champ vide
        // pour inviter à saisir ; un vrai nom (réunion reprise) est repris tel quel.
        .task(id: app.pendingMeeting?.id) {
            let current = app.pendingMeeting?.title ?? ""
            title = current.hasPrefix("Réunion du ") ? "" : current
            selectedTags = Set(app.pendingMeeting?.tags ?? [])
        }
    }

    private var header: String {
        switch app.processingPhase {
        case .some(let p) where p.isFailed: "Échec du traitement"
        case .some(let p) where p.isDone: "Réunion enregistrée"
        case .some: "Traitement en cours"
        case .none: "Nommer la réunion"
        }
    }

    // MARK: Formulaire nom + tags

    @ViewBuilder private var formSection: some View {
        Text("Nom de la réunion").font(.subheadline).foregroundStyle(.secondary)
        TextField("Titre", text: $title).textFieldStyle(.roundedBorder)

        Text("Tags").font(.subheadline).foregroundStyle(.secondary)
        if !tagChoices.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tagChoices, id: \.self) { tag in
                        TagChip(label: tag, selected: selectedTags.contains(tag)) {
                            if selectedTags.contains(tag) { selectedTags.remove(tag) }
                            else { selectedTags.insert(tag) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        HStack {
            TextField("Nouveau tag…", text: $newTag)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addNewTag)
            Button("Ajouter", action: addNewTag)
                .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
        }

        Divider()
        HStack {
            Button("Ouvrir le dossier du Vault") { openVaultRoot() }
                .disabled(app.settings.vaultPath.isEmpty)
            Spacer()
            Button("Valider") {
                Task { await app.nameAndProcess(title: title, tags: Array(selectedTags)) }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Progression / fin

    @ViewBuilder private func progressSection(_ phase: ProcessingPhase) -> some View {
        if let frac = phase.fraction {
            ProgressView(value: frac) { Text(phase.label) }
        } else {
            ProgressView { Text(phase.label) }
        }
        if phase.isDone {
            Label("Analyse terminée", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Divider()
            HStack {
                Button("Ouvrir l'emplacement") { openLocation() }
                Spacer()
                Button("Fermer") { dismissWindow(id: "naming") }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private func failureSection(_ phase: ProcessingPhase) -> some View {
        if case .failed(let message) = phase {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
        }
        Text("Le traitement peut être relancé sans ré-enregistrer.")
            .font(.caption).foregroundStyle(.secondary)
        Divider()
        HStack {
            Button("Fermer") { dismissWindow(id: "naming") }
            Spacer()
            Button("Réessayer") { Task { await app.retryProcessing() } }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Actions

    private var tagChoices: [String] {
        Array(Set(app.allTags).union(selectedTags)).sorted()
    }

    private func addNewTag() {
        let t = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        selectedTags.insert(t)
        newTag = ""
    }

    private func openVaultRoot() {
        guard !app.settings.vaultPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: app.settings.vaultPath))
    }

    private func openLocation() {
        if let url = app.pendingMeeting.flatMap({ app.location(for: $0) }) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}

// ponytail: chip = Button stylé, pas de FlowLayout custom (ScrollView horizontale suffit).
struct TagChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                    in: Capsule())
                .overlay(Capsule().stroke(selected ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Administration (Phase 6)

/// Libellé de réglage avec une icône ⓘ portant une info-bulle (au survol).
private struct InfoLabel: View {
    let title: String
    let help: String

    init(_ title: String, _ help: String) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help(help)
        }
    }
}

struct AdminView: View {
    @Bindable var app: MeetingCoordinator
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var runningApps: [SystemAudioApps.App] = []

    /// Apps proposées dans le sélecteur : celles en cours + l'app déjà choisie même si absente
    /// (sinon le Picker afficherait un blanc à la place de la sélection courante).
    private var systemAppOptions: [SystemAudioApps.App] {
        let selected = app.settings.systemCaptureBundleID
        if !selected.isEmpty, !runningApps.contains(where: { $0.bundleID == selected }) {
            return [SystemAudioApps.App(bundleID: selected, name: selected)] + runningApps
        }
        return runningApps
    }

    var body: some View {
        Form {
            Section("IA générative (OpenAI-compatible)") {
                TextField("Endpoint", text: $app.settings.aiBaseURL)
                    .help("URL de base de l'API OpenAI-compatible (ex. https://api.openai.com/v1). Fonctionne aussi avec Azure, Ollama, LM Studio, vLLM, OpenRouter…")
                TextField("Modèle", text: $app.settings.aiModel)
                    .help("Identifiant du modèle à utiliser (ex. gpt-4o, llama3).")
                HStack {
                    SecureField(
                        app.tokenPresent ? "Token enregistré (Keychain)" : "Token d'authentification",
                        text: $app.tokenInput
                    )
                    .help("Clé d'authentification de l'API, stockée dans le Trousseau (Keychain) — jamais en clair ni dans les journaux.")
                    Button("Enregistrer") { app.commitToken() }
                        .disabled(app.tokenInput.isEmpty)
                }
                HStack {
                    Button("Tester la connexion") { Task { await app.testConnection() } }
                        .help("Envoie un court message à l'endpoint pour vérifier l'URL, le modèle et le token.")
                    if let status = app.connectionStatus {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Stockage") {
                HStack {
                    TextField("Dossier du Vault", text: $app.settings.vaultPath)
                        .help("Dossier où Pépito range transcripts, résumés et plans d'action en Markdown. Portable et versionnable avec git.")
                    Button("Choisir…") { chooseVaultFolder() }
                }
            }

            Section("Prompt d'analyse (structuration après transcript)") {
                TextEditor(text: $app.settings.agenticPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .help("Instructions données à l'IA une fois le transcript prêt : comment résumer, extraire les décisions et hiérarchiser les plans d'action. L'app se charge d'écrire les fichiers dans le Vault — le modèle n'appelle aucun outil.")
                Text("Variables: {{date}}, {{participants}}, {{transcript}}")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Capture & transcription") {
                Toggle(isOn: $app.settings.flags.captureMicrophone) {
                    InfoLabel("Micro", "Enregistre votre voix (entrée micro) et la transcrit sous le libellé « Moi ». Désactivez pour ne capturer que les interlocuteurs.")
                }
                .help("Capture de votre micro — libellé « Moi » dans le transcript.")

                Toggle(isOn: $app.settings.flags.captureSystemAudio) {
                    InfoLabel("Sortie système", "Capture l'audio qui sort de votre Mac (la voix des autres participants) via ScreenCaptureKit — nécessite la permission « Enregistrement de l'écran ». Transcrit sous le libellé « Interlocuteurs ».")
                }
                .help("Capture l'audio des autres participants — libellé « Interlocuteurs ».")

                if app.settings.flags.captureSystemAudio {
                    Picker(selection: $app.settings.systemCaptureBundleID) {
                        Text("Tout le système").tag("")
                        ForEach(systemAppOptions) { option in
                            Text(option.name).tag(option.bundleID)
                        }
                    } label: {
                        InfoLabel("Application ciblée", "Ne capturer que la sortie de cette application (ex. Teams, Zoom) dans la piste « Interlocuteurs » — exclut Spotify, notifications, etc. « Tout le système » capture toutes les apps. Si l'app choisie n'est pas lancée au moment de l'enregistrement, repli automatique sur toute la sortie système.")
                    }
                    .help("Capture ciblée sur une app. Vide = tout le système.")
                    .task { runningApps = await SystemAudioApps.running() }
                }

                Picker(selection: $app.settings.echoCancellation) {
                    ForEach(EchoCancellationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    InfoLabel("Annulation d'écho (micro)", "Retire de la piste « Moi » la voix des interlocuteurs recaptée par le micro sur les haut-parleurs. AEC système : temps réel, optimisée, mais elle prend possession du micro et EMPÊCHE Teams/Zoom de l'utiliser pendant l'enregistrement — à éviter pour enregistrer une visio. AEC hors-ligne (recommandée pour la visio) : laisse le micro partagé avec Teams et traite les fichiers après la réunion, sans toucher au volume (transcription du micro un peu plus longue). Désactivée : utilisez un casque.")
                }
                .help("Stratégie anti-bleed micro. Casque = aucun bleed quel que soit le mode.")

                Toggle(isOn: $app.settings.flags.useOnDeviceAI) {
                    InfoLabel("IA on-device", "À venir : utilise un modèle génératif local (100 % privé, aucune donnée envoyée sur le réseau) au lieu de l'endpoint distant. Tant que non implémenté, l'endpoint OpenAI-compatible est utilisé.")
                }
                .help("À venir — analyse 100 % locale, sans envoi réseau.")

                TextField("Langue de transcription", text: $app.settings.transcriptionLocaleIdentifier)
                    .help("Code de langue BCP-47 pour la transcription (ex. fr-FR, en-US).")
            }

            Section("Journaux") {
                HStack {
                    Button("Ouvrir le journal") { NSWorkspace.shared.open(app.logFileURL) }
                        .help("Ouvre le fichier de journal de Pépito dans l'application par défaut.")
                    Button("Révéler dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.logFileURL])
                    }
                    .help("Sélectionne le fichier de journal dans le Finder.")
                }
            }

            Section {
                Button("Enregistrer les réglages") {
                    app.saveSettings()
                    dismissWindow(id: "settings")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
    }

    private func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            app.settings.vaultPath = url.path
            app.saveSettings()
        }
    }
}
