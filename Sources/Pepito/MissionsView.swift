import AppCore
import SwiftUI
import UniformTypeIdentifiers

struct MissionHistoryRow: View {
    @Bindable var missions: MissionCoordinator
    let mission: Mission
    @State private var hovered = false
    @FocusState private var menuFocused: Bool
    @State private var renaming = false
    @State private var title = ""
    @State private var deleting = false

    var body: some View {
        HStack(spacing: 4) {
            Button { missions.selectedID = mission.id } label: {
                HStack {
                    if mission.isPinned == true { Image(systemName: "pin.fill").font(.caption) }
                    MissionHistoryTitle(title: mission.title, hovered: hovered)
                        .fontWeight(missions.selectedID == mission.id ? .medium : .regular)
                    Spacer(minLength: 2)
                    if missions.runningID == mission.id { MissionSpinner() }
                }
                .contentShape(.rect)
            }.buttonStyle(.plain)
                .accessibilityAddTraits(missions.selectedID == mission.id ? .isSelected : [])
            Menu { actions } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .focused($menuFocused)
            .opacity(hovered || menuFocused || missions.selectedID == mission.id ? 1 : 0)
            .accessibilityLabel("Actions pour \(mission.title)")
            .help("Actions sur la conversation")
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .foregroundStyle(Color(nsColor: .labelColor))
        .tint(.gray)
        .background(
            missions.selectedID == mission.id
                ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                : Color.primary.opacity(hovered ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(missions.selectedID == mission.id ? 0.15 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .contextMenu { actions }
        .alert("Renommer la conversation", isPresented: $renaming) {
            TextField("Nom", text: $title)
            Button("Annuler", role: .cancel) {}
            Button("Enregistrer") { missions.rename(mission.id, to: title) }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Supprimer « \(mission.title) » ?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { missions.delete(mission.id) }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("La conversation, ses fichiers importés et ses livrables locaux seront définitivement supprimés. Les réunions et actions d’origine sont conservées.")
        }
    }

    @ViewBuilder private var actions: some View {
        Button { missions.togglePin(mission.id) } label: {
            Label(mission.isPinned == true ? "Désépingler" : "Épingler", systemImage: "pin")
        }
        Button { title = mission.title; renaming = true } label: {
            Label("Renommer…", systemImage: "pencil")
        }
        Button { missions.setArchived(mission.id, mission.isArchived != true) } label: {
            Label(mission.isArchived == true ? "Désarchiver" : "Archiver", systemImage: "archivebox")
        }.disabled(missions.runningID == mission.id)
        Divider()
        Button(role: .destructive) { deleting = true } label: {
            Label("Supprimer…", systemImage: "trash")
        }.disabled(missions.runningID == mission.id)
    }
}

private struct MissionHistoryTitle: View {
    let title: String
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()
    @State private var textWidth: CGFloat = 0

    var body: some View {
        Text(title).lineLimit(1)
            .opacity(hovered && !reduceMotion ? 0 : 1)
            .overlay {
                if hovered && !reduceMotion {
                    GeometryReader { geometry in
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: textWidth <= geometry.size.width)) { context in
                            let distance = max(0, textWidth - geometry.size.width)
                            let duration = Double(distance / 30)
                            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                                .truncatingRemainder(dividingBy: duration + 2)
                            Text(title).fixedSize()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                                .offset(x: -min(distance, max(0, elapsed - 0.8) * 30))
                        }
                    }.clipped().allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onChange(of: hovered) { startedAt = Date() }
            .onChange(of: title) { startedAt = Date(); textWidth = 0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .help(title)
    }
}

struct MissionsView: View {
    @Bindable var app: MeetingCoordinator
    @Bindable var missions: MissionCoordinator
    @State private var importing = false
    @State private var showingWorkspace = true
    @State private var workspaceTab = "Livrables"
    @State private var preview: URL?
    @State private var showingAccess = false
    @State private var scrollFollowing = ConversationScrollFollowing()
    var body: some View {
        HSplitView {
            if let mission = missions.selected {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(mission.title).font(.title2.bold()).lineLimit(2)
                        Spacer()
                        Button {
                            showingWorkspace.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }.help("Afficher ou masquer l’espace de travail")
                    }
                    Text(missions.runningID == mission.id ? (missions.status ?? "Pépito travaille…") : (mission.state == "done" ? "Mission terminée" : "Décrivez le résultat souhaité.")).font(.caption)
                        .foregroundStyle(
                            .secondary)
                        .modifier(WorkingTextEffect(active: missions.runningID == mission.id && missions.approval == nil))
                    if let error = missions.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(mission.messageGroups) { group in
                                if group.isTools {
                                    MissionToolGroupView(messages: group.messages)
                                } else if let message = group.messages.first {
                                    VStack(alignment: .leading, spacing: 5) {
                                        if message.role != "assistant" {
                                            Text(message.role == "user" ? "Vous" : "Information")
                                                .font(.caption.bold()).foregroundStyle(.secondary)
                                        }
                                        Text(.init(String(message.text.prefix(32_000))))
                                            .textSelection(.enabled)
                                    }.padding(message.role == "user" ? 12 : 0)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            message.role == "user"
                                                ? Color.accentColor.opacity(0.08) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                            ForEach(mission.pendingSteering ?? []) { message in
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(missions.runningID == mission.id ? "Consigne en attente du prochain tour" : "Consigne en attente de reprise",
                                          systemImage: "text.bubble")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(message.text).textSelection(.enabled)
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                            }
                            if !mission.artifacts.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(mission.artifacts, id: \.self) { name in
                                        if let url = missions.artifactURL(name, mission: mission.id) {
                                            HStack {
                                                Button {
                                                    preview = url; workspaceTab = "Livrables"; showingWorkspace = true
                                                } label: {
                                                    Label(name, systemImage: "doc.richtext")
                                                        .font(.callout).lineLimit(1)
                                                }.buttonStyle(.plain)
                                                Spacer()
                                                Menu {
                                                    Button("Ouvrir avec l’application par défaut") { NSWorkspace.shared.open(url) }
                                                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                                    Button("Exporter…") { export(url) }
                                                } label: { Image(systemName: "ellipsis") }
                                                .menuStyle(.borderlessButton).fixedSize()
                                                .help("Actions sur le livrable")
                                            }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                                        }
                                    }
                                }.padding(.top, 6)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(scrollFollowing.followsBottom ? .bottom : nil, for: .sizeChanges)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        ConversationScrollFollowing.isAtBottom(geometry)
                    } action: { _, atBottom in
                        scrollFollowing.geometryChanged(atBottom: atBottom)
                    }
                    .onScrollPhaseChange { _, phase, context in
                        scrollFollowing.phaseChanged(phase, atBottom: ConversationScrollFollowing.isAtBottom(context.geometry))
                    }
                    .id(mission.id)
                    if let approval = missions.approval, missions.runningID == mission.id {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(approval.title).font(.headline)
                            ScrollView { Text(approval.details).textSelection(.enabled) }.frame(
                                maxHeight: 180)
                            HStack {
                                Button("Refuser") { missions.answerApproval(false) }
                                Button("Autoriser cette action") { missions.answerApproval(true) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(
                            Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $missions.draft).font(.body).scrollContentBackground(
                                .hidden
                            )
                            .frame(minHeight: 40, maxHeight: 70)
                            if missions.draft.isEmpty {
                                // Même éditeur et même police : les marges natives suivent le curseur.
                                TextEditor(text: .constant("Confiez une tâche à Pépito…"))
                                    .font(.body).foregroundStyle(.tertiary)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 40, maxHeight: 70)
                                    .allowsHitTesting(false).focusable(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        HStack(spacing: 10) {
                            Button {
                                importing = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .help("Joindre des fichiers").disabled(missions.runningID != nil)
                            Button {
                                showingAccess.toggle()
                            } label: {
                                Image(systemName: "checkmark.shield")
                            }
                            .help("Accès de la mission")
                            .popover(isPresented: $showingAccess) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Accès de la mission").font(.headline)
                                    Toggle(
                                        "Données Pépito",
                                        isOn: Binding(
                                            get: { mission.includePepito },
                                            set: { missions.setIncludePepito($0) }))
                                    Text("Réunions, actions, revues de mails et calendrier.").font(
                                        .caption
                                    ).foregroundStyle(.secondary)
                                    Toggle(
                                        "Internet",
                                        isOn: Binding(
                                            get: { mission.internetEnabled(default: app.settings.missionInternetEnabled) },
                                            set: { missions.setScriptInternet($0) }))
                                    if mission.scriptInternet != nil {
                                        Button("Utiliser le réglage global") { missions.resetInternetOverride() }
                                    }
                                    Text(
                                        "Permet curl, les recherches et les téléchargements. Les scripts pourront transmettre le contenu du scratchpad. Les fichiers personnels restent inaccessibles."
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                    if mission.meetingID != nil {
                                        Text(
                                            "La réunion sélectionnée et ses actions sont incluses."
                                        ).font(.caption)
                                    }
                                }.padding().frame(width: 320).disabled(missions.runningID != nil)
                            }
                            if !mission.importedFiles.isEmpty {
                                Text("\(mission.importedFiles.count) fichier(s)").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(app.settings.aiModel).font(.caption).lineLimit(1).foregroundStyle(
                                .secondary
                            )
                            .help("Sources traitées via \(app.settings.aiBaseURL)")
                            if missions.runningID == mission.id && missions.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button { missions.stop() } label: {
                                    Label("Arrêter la réponse", systemImage: "stop.fill")
                                        .frame(width: 20, height: 20)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                                .help("Arrêter la réponse")
                            } else {
                                Button { app.sendMission() } label: {
                                    Label(mission.state == "interrupted" ? "Reprendre" : "Envoyer", systemImage: "arrow.up")
                                        .frame(width: 20, height: 20)
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                                .help(missions.runningID == mission.id ? "Envoyer une consigne pour le prochain tour" : (mission.state == "interrupted" ? "Reprendre la mission" : "Envoyer"))
                                .disabled(
                                    (missions.runningID != nil && missions.runningID != mission.id)
                                        || missions.draft.trimmingCharacters(
                                            in: .whitespacesAndNewlines
                                        ).isEmpty)
                            }
                        }
                        Text("Les sources consultées sont envoyées à \(app.settings.aiBaseURL).")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }.padding(12).background(
                        .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
                }.padding().frame(minWidth: 380)
                    .onChange(of: mission.artifacts) { old, new in
                        if new.last != old.last, let name = new.last,
                           let url = missions.artifactURL(name, mission: mission.id) {
                            preview = url; workspaceTab = "Livrables"; showingWorkspace = true
                        }
                    }
                if showingWorkspace {
                    VStack(alignment: .leading, spacing: 0) {
                        Picker("Espace de travail", selection: $workspaceTab) {
                            ForEach(["Livrables", "Fichiers", "Sources", "Web"], id: \.self) {
                                Text($0)
                            }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .frame(maxWidth: .infinity)
                        .padding()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if let preview {
                                    HStack {
                                        Text("Aperçu").font(.caption)
                                        Spacer()
                                        Button("Fermer") { self.preview = nil }
                                    }
                                    MissionArtifactPreview(url: preview).id(preview)
                                    HStack {
                                        Button("Ouvrir avec l’application par défaut") { NSWorkspace.shared.open(preview) }
                                        Button("Exporter…") { export(preview) }
                                    }.font(.caption)
                                    Divider()
                                }
                                if workspaceTab == "Livrables" {
                                    Text("Livrables").font(.headline)
                                    ForEach(mission.artifacts, id: \.self) { name in
                                        if let url = missions.artifactURL(name, mission: mission.id) {
                                            HStack {
                                                Button(name) { preview = url }
                                                    .buttonStyle(.link)
                                                Spacer()
                                                Button {
                                                    export(url)
                                                } label: {
                                                    Image(systemName: "square.and.arrow.up")
                                                }.help("Exporter ce livrable")
                                            }
                                        }
                                    }
                                    if mission.artifacts.isEmpty {
                                        Text("Les documents produits apparaîtront ici.").font(.caption)
                                            .foregroundStyle(
                                                .secondary)
                                    }
                                }
                                if workspaceTab == "Fichiers" {
                                    Text("Scratchpad de la mission").font(.headline)
                                    Text("Les fichiers de travail sont conservés pour la reprise.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ForEach(missions.workspaceFiles(mission.id), id: \.self) { url in
                                        Button(url.lastPathComponent) {
                                            preview = missions.previewWorkspaceFile(
                                                url.lastPathComponent, missionID: mission.id)
                                        }.buttonStyle(.link)
                                    }
                                    Divider()
                                    Text("Fichiers importés").font(.headline)
                                    ForEach(mission.importedFiles, id: \.self) { name in
                                        Text(name).font(.caption)
                                    }
                                    Button("Ajouter des fichiers…") { importing = true }.disabled(
                                        missions.runningID != nil)
                                }
                                if workspaceTab == "Sources" {
                                    Text("Sources").font(.headline)
                                    ForEach(mission.sourceSnapshots ?? [], id: \.id) { source in
                                        DisclosureGroup(source.title) {
                                            Text(source.id).font(.caption.monospaced()).textSelection(
                                                .enabled)
                                            Text(String(source.text.prefix(1200))).font(.caption)
                                                .textSelection(.enabled)
                                            if source.kind == "meeting",
                                                let id = UUID(
                                                    uuidString: String(source.id.dropFirst(8)))
                                            {
                                                Button("Ouvrir la réunion") {
                                                    app.selection = .meeting(id)
                                                }
                                            } else if let raw = source.url, let url = URL(string: raw),
                                                ["message", "file", "https"].contains(url.scheme ?? "")
                                            {
                                                Link("Ouvrir la source", destination: url)
                                            }
                                        }.font(.caption)
                                    }
                                }
                                if workspaceTab == "Web" {
                                    Text("Navigateur dédié").font(.headline)
                                    Text("Session WebKit privée, indépendante de Safari.").font(
                                        .caption
                                    )
                                    .foregroundStyle(.secondary)
                                    if missions.runningID == nil || missions.runningID == mission.id {
                                        Toggle("Prendre la main", isOn: $missions.browserManual)
                                        if let webView = missions.browserView {
                                            MissionWebView(webView: webView)
                                                .frame(minHeight: 420)
                                                .allowsHitTesting(missions.browserManual)
                                                .accessibilityLabel("Navigateur de la mission")
                                        }
                                        if missions.browserMissionID == mission.id {
                                            Text(missions.browserURL).font(.caption2).textSelection(.enabled)
                                        }
                                        if missions.browserManual {
                                            TextField("Adresse du site", text: $missions.browserInput)
                                                .onSubmit { missions.manualBrowserCommand("open") }
                                            HStack {
                                                Button("Ouvrir") {
                                                    missions.manualBrowserCommand("open")
                                                }
                                                Button("Retour") {
                                                    missions.manualBrowserCommand("back")
                                                }
                                                Button("Actualiser l’aperçu") {
                                                    missions.manualBrowserCommand("snapshot")
                                                }
                                            }
                                            Text(
                                                "Naviguez, cliquez et saisissez directement dans la page."
                                            ).font(.caption)
                                        }
                                    } else {
                                        Text(
                                            "Le navigateur apparaîtra ici lorsque Pépito consultera un site."
                                        )
                                        .font(.caption).foregroundStyle(.secondary)
                                    }

                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        }
                    }.frame(minWidth: 300, idealWidth: 420, maxWidth: 700)
                }
            } else {
                ContentUnavailableView {
                    Label("Confiez une mission à Pépito", systemImage: "sparkles")
                } description: {
                    Text("Préparer une réunion, analyser des fichiers ou rédiger des relances.")
                } actions: {
                    Button("Nouvelle mission") { app.beginMission() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: missions.selectedID) {
            preview = nil
            scrollFollowing = ConversationScrollFollowing()
        }
        .fileImporter(
            isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true
        ) {
            result in
            if case .success(let urls) = result { for url in urls { missions.importFile(url) } }
        }
    }
    private func export(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try Data(contentsOf: url).write(to: destination, options: .atomic) } catch {
            missions.error = error.localizedDescription
        }
    }
}

/// Seul un geste utilisateur suspend le suivi ; la croissance d’une réponse ne le désactive pas.
struct ConversationScrollFollowing {
    private(set) var followsBottom = true
    private var userScrolling = false

    static func isAtBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentOffset.y + geometry.containerSize.height
            >= geometry.contentSize.height + geometry.contentInsets.bottom - 2
    }

    mutating func phaseChanged(_ phase: ScrollPhase, atBottom: Bool) {
        switch phase {
        case .tracking, .interacting, .decelerating:
            userScrolling = true
            followsBottom = false
        case .idle:
            if userScrolling { followsBottom = atBottom }
            userScrolling = false
        case .animating:
            break
        @unknown default:
            break
        }
    }

    mutating func geometryChanged(atBottom: Bool) {
        if userScrolling { followsBottom = atBottom }
    }
}
