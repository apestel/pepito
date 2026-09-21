import AppCore
import Quartz
import SwiftUI
import WebKit

struct MissionSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            ZStack {
                Circle().stroke(.primary.opacity(0.12), lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.7)
                    .stroke(.primary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(reduceMotion ? -90 : context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1) * 360))
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Traitement en cours")
    }
}

/// Animation limitée aux petits libellés actifs, jamais au corps de la conversation.
struct WorkingTextEffect: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if active && !reduceMotion {
                GeometryReader { geometry in
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 2) / 2
                        LinearGradient(colors: [.clear, .primary.opacity(0.85), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.5)
                            .offset(x: geometry.size.width * (phase * 1.5 - 0.5))
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

struct MissionToolGroupView: View {
    let messages: [MissionMessage]
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(messages) { message in
                    if let tool = message.tool {
                        MissionToolView(tool: tool)
                    } else {
                        Text(message.text).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }.padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: messages.last?.tool?.displayIcon ?? "wrench.and.screwdriver")
                Text(messages.last?.tool?.displayTitle ?? "Appels d’outils")
                    .lineLimit(1)
                .modifier(WorkingTextEffect(active: messages.contains { $0.tool?.state == "running" }))
                if messages.count > 1 { Text("· \(messages.count) appels") }
                Spacer(minLength: 4)
                if messages.contains(where: { $0.tool?.state == "running" }) {
                    MissionSpinner()
                    Text("En cours")
                }
                if messages.contains(where: { $0.tool?.state == "failed" }) {
                    Label("Échec", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                } else if messages.contains(where: { $0.tool?.state == "interrupted" }) {
                    Label("Interrompu", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .disclosureGroupStyle(HoverToolDisclosureStyle())
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.15), value: expanded)
    }
}

private extension MissionToolCall {
    var displayTitle: String {
        switch name {
        case "run_script": "Exécution de code"
        case "search_context": "Recherche dans les sources"
        case "read_source": "Lecture d’une source"
        case "write_artifact": "Création d’un livrable"
        case "read_artifact": "Lecture / publication d’un livrable"
        case "download_file": "Téléchargement"
        case "browser": "Navigateur"
        case "calendar": "Calendrier"
        case "propose_action_status": "Mise à jour d’une action"
        default: name
        }
    }
    var displayIcon: String {
        switch name {
        case "run_script": "terminal"
        case "search_context": "magnifyingglass"
        case "read_source", "read_artifact": "doc.text"
        case "write_artifact": "square.and.pencil"
        case "download_file": "arrow.down.circle"
        case "browser": "globe"
        case "calendar": "calendar"
        case "propose_action_status": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}

private struct HoverToolDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverToolDisclosure(configuration: configuration)
    }
}

private struct HoverToolDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    configuration.label
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 12)
                        .opacity(hovered || focused ? 1 : 0)
                        .accessibilityHidden(true)
                }.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focused($focused)
            .accessibilityValue(configuration.isExpanded ? "Déplié" : "Replié")
            .accessibilityHint("Afficher ou masquer les détails")
            if configuration.isExpanded { configuration.content }
        }
        .onHover { hovered = $0 }
    }
}

private struct MissionToolView: View {
    let tool: MissionToolCall
    @State private var tab = "Réponse"
    private var script: [String: String]? {
        guard tool.name == "run_script",
              let request = try? JSONSerialization.jsonObject(with: Data(tool.request.utf8)) as? [String: Any],
              let code = request["code"] as? String else { return nil }
        return ["code": code, "language": request["language"] as? String ?? ""]
    }
    private var state: String {
        switch tool.state {
        case "running": "En cours"
        case "failed": "Échec"
        case "interrupted": "Résultat incertain"
        default: "Terminé"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(tool.displayTitle, systemImage: tool.displayIcon)
                Spacer()
                if tool.state == "running" {
                    Text(tool.startedAt, style: .timer).monospacedDigit()
                }
                Text(state).foregroundStyle(tool.state == "failed" ? Color.orange : .secondary)
            }.font(.caption)
            if let script {
                Text(script["language"] ?? "").font(.caption).foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(MissionCodeHighlight.render(script["code"] ?? "", language: script["language"] ?? ""))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 280)
                if tool.state == "running" {
                    Text("Résultat disponible à la fin de l’exécution · limite de 60 s")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Détails de l’appel", selection: $tab) {
                ForEach(["Requête", "Vérification", "Réponse"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.vertical, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if tab == "Requête" {
                        code(tool.request)
                    } else if tab == "Vérification" {
                        Text(tool.verification).textSelection(.enabled)
                    } else if let exit = tool.exitCode {
                        Text(
                            "Code de sortie : \(exit) · \(tool.duration ?? 0, specifier: "%.2f") s"
                        )
                        .foregroundStyle(exit == 0 ? Color.secondary : .red)
                        Text("stdout").fontWeight(.semibold)
                        code(tool.stdout.flatMap { $0.isEmpty ? nil : $0 } ?? "(vide)")
                        Text("stderr").fontWeight(.semibold)
                        code(tool.stderr.flatMap { $0.isEmpty ? nil : $0 } ?? "(vide)")
                    } else {
                        code(tool.response.isEmpty ? "En attente du résultat…" : tool.response)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 280)
        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
    private func code(_ text: String) -> some View {
        Text(text).font(.caption.monospaced()).textSelection(.enabled)
    }
}

/// Local preview with no bridge to the app. HTML may compute a visualization but cannot fetch data.
struct MissionArtifactPreview: View {
    let url: URL
    @State private var content: String?
    @State private var source = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                if content != nil { Toggle("Source", isOn: $source).toggleStyle(.button) }
            }
            if let content {
                if ["html", "htm"].contains(url.pathExtension.lowercased()), !source {
                    LocalHTMLPreview(html: content).frame(minHeight: 320)
                } else {
                    ScrollView {
                        if url.pathExtension.lowercased() == "md", !source {
                            MarkdownText(markdown: content).textSelection(.enabled).frame(
                                maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(content).font(.caption.monospaced()).textSelection(.enabled).frame(
                                maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(minHeight: 200, maxHeight: 450)
                }
            } else {
                LocalQuickLookPreview(url: url).frame(minHeight: 300)
            }
        }.task(id: url) {
            source = false
            content = nil
            if ["txt", "md", "json", "csv", "tsv", "py", "js", "html", "htm", "log"].contains(
                url.pathExtension.lowercased())
            {
                content = await Task.detached {
                    guard let h = try? FileHandle(forReadingFrom: url) else {
                        return "Fichier indisponible"
                    }
                    defer { try? h.close() }
                    let bytes = (try? h.read(upToCount: 1_048_577)) ?? Data()
                    guard bytes.count <= 1_048_576 else {
                        return
                            "Aperçu limité à 1 Mio. Exportez le fichier pour le consulter entièrement."
                    }
                    return String(decoding: bytes, as: UTF8.self)
                }.value
            }
        }
    }
}

private struct LocalQuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal)!
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}
private struct LocalHTMLPreview: NSViewRepresentable {
    let html: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        let document = html
        // Install blocking rules before loading any model-generated HTML (including CSS URLs).
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PepitoLocalPreview",
            encodedContentRuleList:
                #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]"#
        ) { rules, error in
            guard let rules, error == nil else { return }
            view.configuration.userContentController.add(rules)
            view.loadHTMLString(
                "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; form-action 'none'; frame-src 'none'\">"
                    + document, baseURL: nil)
        }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String?
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(
                action.navigationType == .other && action.request.url?.scheme == "about"
                    ? .allow : .cancel)
        }
    }
}

struct MissionWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
