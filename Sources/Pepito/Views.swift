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

            Button { open("main") } label: {
                Label("Fenêtre principale (direct, réunions & suivi)", systemImage: "sidebar.left")
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

    /// Sélection de la barre latérale : le transcript live (pendant un enregistrement), le suivi
    /// transverse, ou une réunion. Le dashboard doit rester atteignable ; il n'est donc plus caché
    /// derrière « aucune sélection ».
    enum SidebarItem: Hashable {
        case live
        case dashboard
        case mailReview(String)
        case meeting(Meeting.ID)
    }
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                // « En direct » en première position, seulement pendant un enregistrement.
                if app.isRecording {
                    Label("En direct", systemImage: "waveform")
                        .foregroundStyle(.red)
                        .tag(SidebarItem.live)
                }
                Label("Suivi", systemImage: "checklist").tag(SidebarItem.dashboard)
                Section {
                    // Avancement/bilan du triage : la seule trace visible quand l'historique est
                    // encore vide (le triage dure ~1 min).
                    if app.isTriagingMail || app.mailStatus != nil {
                        HStack(spacing: 6) {
                            if app.isTriagingMail { ProgressView().controlSize(.small) }
                            Text(app.mailStatus ?? "Triage en cours…")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .help(app.mailStatus ?? "")
                        .selectionDisabled()
                    }
                    if app.mailReviews.isEmpty, !app.isTriagingMail {
                        Text("Aucune revue").foregroundStyle(.secondary).selectionDisabled()
                    }
                    ForEach(app.mailReviews) { review in
                        MailReviewRow(review: review).tag(SidebarItem.mailReview(review.date))
                    }
                } header: {
                    HStack {
                        Text("Mails")
                        Spacer()
                        Menu {
                            Button("Aujourd'hui") { Task { await app.triageMail(days: 1) } }
                            Button("7 derniers jours") { Task { await app.triageMail(days: 7) } }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .disabled(app.isTriagingMail)
                        .help("Trier mes mails : lit Mail, classe les conversations et en extrait vos actions.")
                    }
                }
                Section("Réunions") {
                    if app.meetings.isEmpty {
                        Text("Aucune réunion").foregroundStyle(.secondary)
                    }
                    ForEach(app.meetings) { meeting in
                        MeetingRow(meeting: meeting).tag(SidebarItem.meeting(meeting.id))
                    }
                }
            }
            .navigationTitle("Pépito")
            .frame(minWidth: 240)
        } detail: {
            if selection == .live {
                LiveTranscriptView(app: app)
            } else if case .meeting(let id) = selection, let meeting = app.meetings.first(where: { $0.id == id }) {
                MeetingDetailView(app: app, meeting: meeting)
            } else if case .mailReview(let date) = selection,
                      let review = app.mailReviews.first(where: { $0.date == date }) {
                MailReviewView(app: app, review: review)
            } else {
                DashboardView(app: app)
            }
        }
        // Bascule sur « En direct » au démarrage d'un enregistrement, revient au suivi à l'arrêt
        // (l'onglet live disparaît alors de la barre latérale).
        .onChange(of: app.isRecording) { _, recording in
            selection = recording ? .live : .dashboard
        }
        // Un triage qui aboutit amène directement sa revue à l'écran.
        .onChange(of: app.lastMailReviewDate) { _, date in
            if let date { selection = .mailReview(date) }
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

/// Ligne d'historique d'une revue de mails : date courte + ce qui reste urgent.
struct MailReviewRow: View {
    let review: MailReviewSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(Self.label(review.date)).font(.body)
                Text("\(review.threadCount) conversations")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if review.immediateCount > 0 {
                Text("🔴 \(review.immediateCount)").font(.caption2)
            }
            if review.flaggedCount > 0 {
                Text("⚑ \(review.flaggedCount)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// « 2026-07-26 » → « 26 juil. » ; on garde la chaîne brute si elle n'est pas au format attendu.
    static func label(_ date: String) -> String {
        guard let parsed = isoDay.date(from: date) else { return date }
        return parsed.formatted(.dateTime.day().month(.abbreviated))
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
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
    @State private var confirmDelete = false
    /// Résumé lu depuis le Vault (fichier, donc chargé à la sélection et non à chaque rendu).
    @State private var summary: String?
    @State private var editingSummary = false
    @State private var summaryDraft = ""

    private var meetingActions: [ActionItem] {
        app.actions.filter { $0.meetingID == meeting.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(meeting.title).font(.largeTitle.bold())
                    StatusBadge(status: meeting.status)
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
                ValueListEditor(
                    systemImage: "person.2", title: "Participants",
                    placeholder: "Ajouter un participant…", values: meeting.participants
                ) { updated in
                    var m = meeting; m.participants = updated; app.updateMeeting(m)
                }
                ValueListEditor(
                    systemImage: "tag", title: "Tags", placeholder: "Ajouter un tag…",
                    values: meeting.tags, suggestions: app.allTags
                ) { updated in
                    var m = meeting; m.tags = updated; app.updateMeeting(m)
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

                GroupBox("Résumé") {
                    if editingSummary {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $summaryDraft)
                                .font(.body.monospaced())
                                .frame(minHeight: 240)
                            HStack {
                                Button("Annuler") { editingSummary = false }
                                Spacer()
                                Button("Enregistrer") {
                                    app.saveSummary(summaryDraft, for: meeting)
                                    summary = app.summaryMarkdown(for: meeting)   // relu du Vault
                                    editingSummary = false
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                    } else {
                        // Double-clic n'importe où dans le corps → édition Markdown.
                        Group {
                            if let summary {
                                MarkdownText(markdown: summary)
                            } else {
                                Text(meeting.status == .done ? "Aucun résumé dans le Vault" : "Résumé disponible après l'analyse")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture(count: 2) {
                            summaryDraft = summary ?? ""
                            editingSummary = true
                        }
                        .help("Double-cliquer pour modifier le résumé (Markdown)")
                    }
                }

                GroupBox("Plans d'action (\(meetingActions.count))") {
                    if meetingActions.isEmpty {
                        Text("Aucune action extraite").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(meetingActions) { action in
                            ActionRow(app: app, action: action)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Supprimer « \(meeting.title) » ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer la réunion", role: .destructive) { app.deleteMeeting(meeting) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les notes, le résumé, le plan d'action et l'audio de cette réunion seront définitivement supprimés du Vault et du disque.")
        }
        // Relit aussi quand le statut change (le résumé n'existe qu'après l'analyse).
        .task(id: [meeting.id.uuidString, meeting.status.rawValue]) {
            summary = app.summaryMarkdown(for: meeting)
            editingSummary = false   // sinon un brouillon suivrait la sélection sur une autre réunion
        }
    }
}

// MARK: - Revue de mails

/// Une revue de mails, consultable sans quitter Pépito : sections par urgence, une carte par
/// conversation, et l'action créée éditable sur place. Le Markdown du Vault reste écrit pour la
/// portabilité, il n'est plus le moyen de lecture.
struct MailReviewView: View {
    @Bindable var app: MeetingCoordinator
    let review: MailReviewSummary
    /// Conversations lues à la sélection (requête base), pas à chaque rendu.
    @State private var entries: [MailReviewEntry] = []
    @State private var expanded: Set<String> = [MailBucket.immediate.rawValue]
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                ForEach(MailBucket.allCases, id: \.self) { bucket in
                    let items = entries.filter { $0.bucket == bucket && !isSettled($0) }
                    if !items.isEmpty {
                        DisclosureGroup(isExpanded: expansion(bucket.rawValue)) {
                            VStack(spacing: 8) {
                                ForEach(items) { MailEntryCard(app: app, entry: $0) }
                            }
                            .padding(.top, 6)
                        } label: {
                            sectionLabel(bucket.rawValue, "\(bucket.title) (\(items.count))")
                        }
                    }
                }

                let archived = MailReview.archiveGroups(entries) { $0.bucket == nil || isSettled($0) }
                if !archived.isEmpty {
                    DisclosureGroup(isExpanded: expansion("archive")) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(archived, id: \.sender) { group in
                                Text(group.count > 1 ? "\(group.sender) ×\(group.count)" : group.sender)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        sectionLabel("archive", "⚪ Peut être archivé (\(archived.reduce(0) { $0 + $1.count }))")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Supprimer la revue du \(MailReviewRow.label(review.date)) ?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer la revue", role: .destructive) { app.deleteMailReview(date: review.date) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Seul l'historique affiché ici est effacé : les actions créées restent dans le suivi, et le document Markdown reste dans le Vault.")
        }
        .task(id: review.date) { entries = app.mailReview(date: review.date) }
        // Retrier le même jour ne change pas la date sélectionnée : sans ça, la vue garderait les
        // conversations de la revue précédente.
        .onChange(of: app.isTriagingMail) { _, running in
            if !running { entries = app.mailReview(date: review.date) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Revue du \(MailReviewRow.label(review.date))").font(.largeTitle.bold())
                Spacer()
                Menu {
                    Button("Aujourd'hui") { Task { await app.triageMail(days: 1) } }
                    Button("7 derniers jours") { Task { await app.triageMail(days: 7) } }
                } label: {
                    Label("Retrier", systemImage: "arrow.clockwise")
                }
                .fixedSize()
                .disabled(app.isTriagingMail)
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Supprimer", systemImage: "trash")
                }
            }
            Text("\(review.messageCount) messages · \(review.threadCount) conversations · \(review.actionCount) action(s)")
                .foregroundStyle(.secondary)
            if app.isTriagingMail || app.mailStatus != nil {
                HStack(spacing: 8) {
                    if app.isTriagingMail { ProgressView().controlSize(.small) }
                    if let status = app.mailStatus {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Label(app.mailReportPath(date: review.date), systemImage: "doc.text")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { isOpen in
                if isOpen { expanded.insert(key) } else { expanded.remove(key) }
            })
    }

    /// Titre de section pliable : sur macOS, seul le chevron d'un `DisclosureGroup` réagit au clic,
    /// or c'est le titre qu'on vise. Toute la ligne devient cliquable.
    private func sectionLabel(_ key: String, _ text: String) -> some View {
        Text(text).font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { expansion(key).wrappedValue.toggle() }
    }

    /// Conversation traitée : son action est terminée ou abandonnée. Elle quitte sa section
    /// d'urgence (et son compteur) pour l'archive.
    private func isSettled(_ entry: MailReviewEntry) -> Bool {
        guard let id = entry.actionID, let action = app.actions.first(where: { $0.id == id })
        else { return false }
        return !action.isOpen
    }
}

/// Une conversation triée : le jugement de l'IA + l'action qu'elle a produite, éditable ici même.
struct MailEntryCard: View {
    @Bindable var app: MeetingCoordinator
    let entry: MailReviewEntry

    private var action: ActionItem? {
        entry.actionID.flatMap { id in app.actions.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.subject).font(.headline)
                if entry.flagged { Text("⚑") }
                if entry.messageCount > 1 {
                    Text("\(entry.messageCount) mails").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = URL(string: entry.url) {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "envelope") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Ouvrir la conversation dans Mail")
                }
            }
            Text(details).font(.caption).foregroundStyle(.secondary)
            if !entry.summary.isEmpty { Text(entry.summary).font(.callout) }
            if !entry.why.isEmpty {
                Text(entry.why).font(.callout).foregroundStyle(.secondary).italic()
            }
            if let action {
                Divider()
                ActionRow(app: app, action: action, showsSource: false)   // l'enveloppe est déjà en tête de carte
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    /// « Rémi Dupont · Haute · Répondre · échéance 28 juil. »
    private var details: String {
        var parts = [entry.sender]
        if !entry.importance.isEmpty { parts.append(entry.importance) }
        if !entry.action.isEmpty { parts.append(entry.action) }
        if !entry.deadline.isEmpty { parts.append("échéance \(MailReviewRow.label(entry.deadline))") }
        if entry.unread > 0 { parts.append("\(entry.unread) non lu(s)") }
        return parts.joined(separator: " · ")
    }
}

/// Rendu Markdown minimal : SwiftUI ne restitue nativement que l'inline (gras/italique/liens),
/// donc titres et puces sont stylés ligne à ligne. Pas de `textSelection` : la sélection capte le
/// double-clic, qui sert à passer en édition (cf. `MeetingDetailView`) ; on copie depuis l'éditeur.
// ponytail: rendu ligne à ligne ; passer à un vrai parseur si tableaux/blocs de code arrivent.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw)
            }
        }
    }

    @ViewBuilder private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else if hashes > 0, trimmed.dropFirst(hashes).hasPrefix(" ") {
            inline(String(trimmed.dropFirst(hashes + 1)))
                .font(hashes == 1 ? .title2.bold() : hashes == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(String(trimmed.dropFirst(2)))
            }
            .padding(.leading, CGFloat(raw.prefix(while: { $0 == " " }).count / 2) * 14)
        } else if trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 3 {
            Divider()
        } else {
            inline(trimmed)
        }
    }

    /// Inline-only : conserve les `#`/`-` déjà traités ci-dessus et évite qu'un `%` du texte
    /// soit interprété comme un format.
    private func inline(_ text: String) -> Text {
        let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return Text(parsed ?? AttributedString(text))
    }
}

/// Édition d'une liste de valeurs (participants, tags) : ligne de résumé compacte + popover
/// contenant une liste **scrollable**, une ligne par valeur. Les chips en ligne devenaient
/// illisibles au-delà de quelques participants (débordement horizontal) ; ici 30 participants
/// restent lisibles et supprimables un par un. Le parent reçoit la liste complète à chaque
/// modification (il persiste, aucun état local à resynchroniser).
struct ValueListEditor: View {
    let systemImage: String
    let title: String
    let placeholder: String
    let values: [String]
    var suggestions: [String] = []
    let onChange: ([String]) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Label(values.isEmpty ? "Aucun" : values.joined(separator: ", "), systemImage: systemImage)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2)
            Button { editing = true } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Modifier : \(title.lowercased())")
            Spacer()
        }
        .popover(isPresented: $editing, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) (\(values.count))").font(.headline)
            if values.isEmpty {
                Text("Aucun pour l'instant").font(.callout).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(values, id: \.self) { value in
                        HStack {
                            Text(value).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { onChange(values.filter { $0 != value }) } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Retirer")
                        }
                    }
                }
                .frame(height: min(CGFloat(values.count) * 26 + 12, 220))
            }
            HStack {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(draft) }
                Button("Ajouter") { add(draft) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                let unused = suggestions.filter { !values.contains($0) }.sorted()
                if !unused.isEmpty {
                    Menu {
                        ForEach(unused, id: \.self) { s in Button(s) { add(s) } }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Reprendre une valeur existante")
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func add(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !value.isEmpty, !values.contains(value) else { return }
        onChange(values + [value])
    }
}

struct ActionRow: View {
    @Bindable var app: MeetingCoordinator
    let action: ActionItem
    /// Bouton « ouvrir le mail d'origine ». Masqué dans une carte de revue, qui porte déjà le sien.
    var showsSource = true
    @State private var editing = false

    var body: some View {
        HStack(alignment: .top) {
            // Menu de statut : éditer le suivi (persisté via updateActionStatus).
            Menu {
                ForEach(ActionStatus.allCases, id: \.self) { status in
                    Button {
                        app.updateActionStatus(action.id, to: status)
                    } label: {
                        Label(Self.label(status), systemImage: Self.symbol(status))
                    }
                }
            } label: {
                Image(systemName: Self.symbol(action.status))
                    .foregroundStyle(action.status == .done ? .green : .secondary)
            }
            .menuStyle(.borderlessButton).fixedSize()
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
            // Action issue d'un mail : ouvrir la conversation d'origine dans Mail.
            if showsSource, let source = action.sourceURL, let url = URL(string: source) {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "envelope") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Ouvrir le mail d'origine")
            }
            Button { editing = true } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Modifier l'action")
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $editing) {
            ActionEditor(action: action) { app.updateAction($0) }
        }
    }

    static func symbol(_ s: ActionStatus) -> String {
        switch s {
        case .todo: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.circle"
        case .done: "checkmark.circle.fill"
        case .dropped: "xmark.circle"
        }
    }
    static func label(_ s: ActionStatus) -> String {
        switch s {
        case .todo: "À faire"
        case .inProgress: "En cours"
        case .blocked: "Bloquée"
        case .done: "Terminée"
        case .dropped: "Abandonnée"
        }
    }
}

/// Édition d'une action : titre, détail, responsable, échéance, priorité, statut.
struct ActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ActionItem
    @State private var hasDue: Bool
    @State private var due: Date
    let onSave: (ActionItem) -> Void

    init(action: ActionItem, onSave: @escaping (ActionItem) -> Void) {
        _draft = State(initialValue: action)
        _hasDue = State(initialValue: action.dueDate != nil)
        _due = State(initialValue: action.dueDate ?? Date())
        self.onSave = onSave
    }

    var body: some View {
        Form {
            TextField("Titre", text: $draft.title)
            TextField("Détail", text: $draft.details, axis: .vertical).lineLimit(2...5)
            TextField("Responsable", text: Binding(
                get: { draft.owner ?? "" },
                set: { draft.owner = $0.isEmpty ? nil : $0 }))
            Toggle("Échéance", isOn: $hasDue)
            if hasDue {
                DatePicker("Le", selection: $due, displayedComponents: .date)
            }
            Picker("Priorité", selection: $draft.priority) {
                Text("Basse").tag(ActionPriority.low)
                Text("Moyenne").tag(ActionPriority.medium)
                Text("Haute").tag(ActionPriority.high)
            }
            Picker("Statut", selection: $draft.status) {
                ForEach(ActionStatus.allCases, id: \.self) { s in
                    Text(ActionRow.label(s)).tag(s)
                }
            }
            Section {
                HStack {
                    Button("Annuler") { dismiss() }
                    Spacer()
                    Button("Enregistrer") {
                        draft.dueDate = hasDue ? due : nil
                        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(draft)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

/// Tableau de bord de suivi (Phase 7) : actions ouvertes et en retard, transverses aux réunions.
struct DashboardView: View {
    @Bindable var app: MeetingCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Suivi").font(.largeTitle.bold())
                    Spacer()
                    Button {
                        Task { await app.exportOpenActionsToReminders() }
                    } label: {
                        Label("Exporter vers Rappels", systemImage: "checklist")
                    }
                    .disabled(app.openActions.isEmpty)
                }

                let overdue = app.overdueActions()
                if !overdue.isEmpty {
                    GroupBox("En retard (\(overdue.count))") {
                        ForEach(overdue) { ActionRow(app: app, action: $0) }
                    }
                }

                GroupBox("Actions ouvertes (\(app.openActions.count))") {
                    if app.openActions.isEmpty {
                        Text("Rien à suivre pour l'instant").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(app.openActions) { ActionRow(app: app, action: $0) }
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

            // Pré-brief (Phase D) : ce qui restait ouvert avec ces participants.
            if !app.preBrief.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("À suivre depuis les réunions précédentes", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ForEach(app.preBrief.prefix(5)) { a in
                            Text("• \(a.title)" + (a.owner.map { " (@\($0))" } ?? "")).font(.callout)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
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
                // Sans animation : le transcript change plusieurs fois par seconde (hypothèses
                // volatiles), et des scrolls animés qui se chevauchent maintiennent un rendu à
                // 60 Hz en permanence pendant toute la réunion.
                .onChange(of: live) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            // Notes de l'utilisateur : l'IA les enrichit en fin de réunion (Phase C).
            Label("Mes notes", systemImage: "square.and.pencil").font(.subheadline).foregroundStyle(.secondary)
            TextEditor(text: $app.draftNotes)
                .font(.body)
                .frame(minHeight: 60, maxHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        .padding()
        .frame(minWidth: 380, minHeight: 340)
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

        Text("Mes notes (enrichies par l'IA)").font(.subheadline).foregroundStyle(.secondary)
        TextEditor(text: $app.draftNotes)
            .font(.body)
            .frame(minHeight: 60, maxHeight: 140)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

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
                Text("Variables: {{date}}, {{participants}}, {{transcript}}, {{context}}, {{user_notes}}, {{open_actions}}, {{vault_tree}}")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Triage des mails") {
                Stepper(value: $app.settings.mailDays, in: 1...30) {
                    InfoLabel("Période par défaut : \(app.settings.mailDays) jour(s)", "Ancienneté maximale des mails analysés. 1 = revue quotidienne, 7 = revue hebdomadaire.")
                }
                Stepper(value: $app.settings.mailLimit, in: 50...1000, step: 50) {
                    InfoLabel("Limite : \(app.settings.mailLimit) messages", "Garde-fou sur les grosses boîtes : au-delà, l'extraction devient très lente (elle passe par Mail, comptez ~1 min pour 7 jours).")
                }
                TextEditor(text: $app.settings.mailPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .help("Instructions données à l'IA pour classer les conversations : critères d'importance, échéances, quoi ignorer. L'app se charge du rendu de la revue et de la création des actions.")
                Text("Variables: {{date}}, {{days}}, {{open_actions}}")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Nécessite l'autorisation Automatisation → Mail au premier triage. Seul un résumé compact (expéditeur, date, 300 caractères d'aperçu) est envoyé à l'IA — jamais les mails complets.")
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
