import AppCore
import Quartz
import SwiftUI
import WebKit

struct MissionToolGroupView: View {
    let messages: [MissionMessage]
    var body: some View {
        DisclosureGroup {
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
                Image(systemName: "wrench.and.screwdriver")
                Text(
                    "\(messages.count) outil\(messages.count > 1 ? "s" : "") appelé\(messages.count > 1 ? "s" : "")"
                )
                if messages.contains(where: { $0.tool?.state == "running" }) {
                    ProgressView().controlSize(.mini)
                }
                if messages.contains(where: { $0.tool?.state == "failed" }) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MissionToolView: View {
    let tool: MissionToolCall
    @State private var tab = "Réponse"
    private var label: String {
        switch tool.name {
        case "run_script": "Exécution de code"
        case "search_context": "Recherche dans les sources"
        case "read_source": "Lecture d’une source"
        case "write_artifact": "Création d’un livrable"
        case "read_artifact": "Lecture / publication d’un livrable"
        case "download_file": "Téléchargement"
        case "browser": "Navigateur"
        case "calendar": "Calendrier"
        case "propose_action_status": "Mise à jour d’une action"
        default: tool.name
        }
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
        DisclosureGroup {
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
        } label: {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                Text(state).foregroundStyle(tool.state == "failed" ? Color.orange : .secondary)
            }.font(.caption)
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
                            Text(.init(content)).textSelection(.enabled).frame(
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
