import AppCore
import SwiftUI
import UniformTypeIdentifiers

struct MissionsView: View {
    @Bindable var app: MeetingCoordinator
    @Bindable var missions: MissionCoordinator
    @State private var importing = false
    @State private var showingWorkspace = true
    @State private var workspaceTab = "Livrables"
    @State private var preview: URL?
    @State private var showingAccess = false
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
                        if missions.runningID == mission.id {
                            ProgressView().controlSize(.small)
                            Button("Arrêter", role: .destructive) { missions.stop() }
                        }
                    }
                    Text(missions.runningID == mission.id ? (missions.status ?? "Pépito travaille…") : (mission.state == "done" ? "Mission terminée" : "Décrivez le résultat souhaité.")).font(.caption)
                        .foregroundStyle(
                            .secondary)
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
                            if missions.draft.isEmpty {
                                Text("Confiez une tâche à Pépito…").foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $missions.draft).font(.body).scrollContentBackground(
                                .hidden
                            )
                            .frame(minHeight: 60, maxHeight: 100)
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
                                        "Internet pour les scripts",
                                        isOn: Binding(
                                            get: { mission.scriptInternet == true },
                                            set: { missions.setScriptInternet($0) }))
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
                            Button(mission.state == "interrupted" ? "Reprendre" : "Envoyer") {
                                app.sendMission()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                missions.runningID != nil
                                    || missions.draft.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty)
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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Picker("Espace de travail", selection: $workspaceTab) {
                                ForEach(["Livrables", "Fichiers", "Sources", "Web"], id: \.self) {
                                    Text($0)
                                }
                            }.pickerStyle(.segmented).labelsHidden()
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
                        }.padding()
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
        .onChange(of: missions.selectedID) { preview = nil }
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
