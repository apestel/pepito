import AppCore
import SwiftUI
import UniformTypeIdentifiers

struct MissionsView: View {
    @Bindable var app: MeetingCoordinator
    @Bindable var missions: MissionCoordinator
    @State private var importing = false
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Missions").font(.title2.bold())
                    Spacer()
                    Button {
                        app.beginMission()
                    } label: {
                        Image(systemName: "plus")
                    }.help("Nouvelle mission")
                }.padding(.horizontal)
                List(selection: $missions.selectedID) {
                    ForEach(missions.items) { mission in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(mission.title).lineLimit(2)
                            Text(stateLabel(mission.state)).font(.caption).foregroundStyle(.secondary)
                        }.tag(mission.id)
                    }
                }
            }.padding(.top).frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            if let mission = missions.selected {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(mission.title).font(.title2.bold()).lineLimit(2)
                        Spacer()
                        if missions.runningID != nil {
                            ProgressView().controlSize(.small)
                            Button("Arrêter", role: .destructive) { missions.stop() }
                        }
                    }
                    Text(missions.status ?? "Décrivez le résultat souhaité.").font(.caption).foregroundStyle(
                        .secondary)
                    if let error = missions.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(mission.messages) { message in
                                if message.role == "tool" {
                                    DisclosureGroup(String(message.text.prefix(100))) {
                                        Text(message.text).font(.caption.monospaced()).textSelection(.enabled)
                                    }.font(.caption).foregroundStyle(.secondary)
                                } else {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(
                                            message.role == "user"
                                                ? "Vous"
                                                : message.role == "assistant" ? "Pépito" : "Information"
                                        ).font(.caption.bold()).foregroundStyle(.secondary)
                                        Text(message.text).textSelection(.enabled)
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            message.role == "user"
                                                ? Color.accentColor.opacity(0.08)
                                                : Color.secondary.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let approval = missions.approval, missions.runningID == mission.id {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(approval.title).font(.headline)
                            Text(approval.details).textSelection(.enabled)
                            HStack {
                                Button("Refuser") { missions.answerApproval(false) }
                                Button("Autoriser cette action") { missions.answerApproval(true) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(
                            Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Toggle(
                        "Autoriser réunions, actions, revues de mails et calendrier",
                        isOn: Binding(get: { mission.includePepito }, set: { missions.setIncludePepito($0) })
                    )
                    .disabled(missions.runningID != nil).font(.caption)
                    if mission.meetingID != nil {
                        Text("La réunion sélectionnée et ses actions sont incluses.").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Ajouter des fichiers…") { importing = true }.disabled(
                            missions.runningID != nil)
                        Text("\(mission.importedFiles.count) fichier(s)").font(.caption).foregroundStyle(
                            .secondary)
                    }
                    TextEditor(text: $missions.draft).font(.body).frame(minHeight: 70, maxHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    HStack {
                        Text(
                            "Les sources consultées seront traitées par \(app.settings.aiModel) via \(app.settings.aiBaseURL)."
                        )
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button(mission.state == "interrupted" ? "Reprendre" : "Confier à Pépito") {
                            app.sendMission()
                        }
                        .buttonStyle(.borderedProminent).disabled(
                            missions.runningID != nil
                                || missions.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding().frame(minWidth: 380)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Livrables").font(.headline)
                        ForEach(mission.artifacts, id: \.self) { name in
                            if let url = missions.artifactURL(name, mission: mission.id) {
                                HStack {
                                    Button(name) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
                            Text("Les documents produits apparaîtront ici.").font(.caption).foregroundStyle(
                                .secondary)
                        }
                        Divider()
                        Text("Sources").font(.headline)
                        ForEach(mission.sourceSnapshots ?? [], id: \.id) { source in
                            DisclosureGroup(source.title) {
                                Text(source.id).font(.caption.monospaced()).textSelection(.enabled)
                                Text(String(source.text.prefix(1200))).font(.caption).textSelection(.enabled)
                                if source.kind == "meeting",
                                    let id = UUID(uuidString: String(source.id.dropFirst(8)))
                                {
                                    Button("Ouvrir la réunion") { app.selection = .meeting(id) }
                                } else if let raw = source.url, let url = URL(string: raw),
                                    ["message", "file", "https"].contains(url.scheme ?? "")
                                {
                                    Link("Ouvrir la source", destination: url)
                                }
                            }.font(.caption)
                        }
                        Divider()
                        Text("Navigateur dédié").font(.headline)
                        if missions.runningID == mission.id, let data = missions.browserImage,
                            let image = NSImage(data: data)
                        {
                            GeometryReader { geo in
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                    .onTapGesture(coordinateSpace: .local) { point in
                                        missions.manualBrowserClick(
                                            x: point.x / geo.size.width * 1100,
                                            y: point.y / geo.size.width * 1100)
                                    }
                            }.aspectRatio(1100.0 / 700.0, contentMode: .fit)
                            Text(missions.browserURL).font(.caption2).textSelection(.enabled)
                        }
                        if missions.runningID == mission.id {
                            Toggle("Prendre la main", isOn: $missions.browserManual)
                            if missions.browserManual {
                                TextField("Adresse du site", text: $missions.browserInput)
                                Button("Ouvrir le site") { missions.manualBrowserCommand("open") }
                                Text("Cliquez dans l’aperçu, puis saisissez le texte.").font(.caption)
                                TextField("Sélecteur (facultatif)", text: $missions.browserSelector)
                                SecureField("Texte à saisir", text: $missions.browserText)
                                HStack {
                                    Button("Cliquer") { missions.manualBrowserCommand("click") }
                                    Button("Saisir") { missions.manualBrowserCommand("fill") }
                                    Button("Entrée") { missions.manualBrowserCommand("enter") }
                                }
                                Button("Actualiser l’aperçu") { missions.manualBrowserCommand("snapshot") }
                            }
                        }
                    }.padding()
                }.frame(minWidth: 230, idealWidth: 300, maxWidth: 480)
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            result in
            if case .success(let urls) = result { for url in urls { missions.importFile(url) } }
        }
    }
    private func stateLabel(_ state: String) -> String {
        switch state {
        case "running": "En cours"
        case "waiting": "Votre validation est nécessaire"
        case "interrupted": "À reprendre"
        case "done": "Terminée"
        default: "Prête"
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
