import AgentKit
import Foundation
import WebKit

/// Ephemeral WebKit session, separate from Safari and from the script scratchpad.
@MainActor
final class MissionBrowser: NSObject, WKNavigationDelegate {
    struct Result {
        var text: String
        var url: String
        var image: Data?
    }
    let webView: WKWebView
    var isManual: () -> Bool = { false }
    private var navigation: CheckedContinuation<Void, Error>?
    private var busy = false
    private var hosts: Set<String> = []
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1100, height: 700), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }
    func command(args: [String: AgentValue]) async throws -> Result {
        guard !busy else { throw AgentError.unavailable("Le navigateur travaille déjà") }
        busy = true
        defer { busy = false }
        let operation = args["operation"]?.string ?? "snapshot"
        let deadline = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled {
                self.finish(AgentError.unavailable("Délai de navigation dépassé"))
                self.webView.stopLoading()
            }
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            if operation == "open" {
                guard let raw = args["url"]?.string, let url = URL(string: raw),
                    ["https", "http"].contains(url.scheme), let host = url.host,
                    url.user == nil, url.password == nil
                else { throw AgentError.unavailable("URL HTTP(S) requise") }
                hosts.insert(host)
                try await withCheckedThrowingContinuation { continuation in
                    navigation = continuation
                    webView.load(URLRequest(url: url, timeoutInterval: 25))
                }
            } else if operation == "back" {
                if webView.canGoBack {
                    try await withCheckedThrowingContinuation { continuation in
                        navigation = continuation
                        webView.goBack()
                    }
                }
            } else if ["click", "fill", "enter"].contains(operation) {
                let data = try JSONEncoder().encode(args)
                let json = String(decoding: data, as: UTF8.self)
                // Only this fixed script is evaluated; model arguments are JSON data.
                _ = try await webView.evaluateJavaScript(
                    """
                    (() => {
                      const a = \(json);
                      const e = a.selector ? document.querySelector(a.selector) :
                        (Number.isFinite(a.x) && Number.isFinite(a.y) ? document.elementFromPoint(a.x,a.y) : document.activeElement);
                      if (!e) throw Error('Élément introuvable');
                      if (a.operation === 'click') e.click();
                      else if (a.operation === 'fill') {
                        if (!['INPUT','TEXTAREA'].includes(e.tagName)) throw Error('Champ de texte requis');
                        e.focus(); e.value = a.text || ''; e.dispatchEvent(new Event('input',{bubbles:true}));
                        e.dispatchEvent(new Event('change',{bubbles:true}));
                      } else if(e.form) e.form.requestSubmit();
                      return true;
                    })()
                    """)
            } else if operation != "snapshot" {
                throw AgentError.unavailable("Opération inconnue")
            }
            try Task.checkCancellation()
            let text =
                try await webView.evaluateJavaScript(
                    """
                    (document.body?.innerText || '').slice(0,12000) + '\\n' + JSON.stringify(
                      Array.from(document.querySelectorAll('a,button,input,textarea,select')).slice(0,70)
                        .map(e => ({tag:e.tagName,text:(e.innerText || e.getAttribute('aria-label') || '').slice(0,100),id:e.id,name:e.name})))
                    """) as? String ?? ""
            let image = try await webView.takeSnapshot(configuration: nil)
            return Result(
                text: text, url: webView.url?.absoluteString ?? "", image: image.tiffRepresentation)
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }
    func stop() {
        webView.stopLoading()
        finish(CancellationError())
    }
    private func finish(_ error: Error? = nil) {
        let waiter = navigation
        navigation = nil
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) { finish(error) }
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url, ["https", "http"].contains(url.scheme),
            let host = url.host, url.user == nil, url.password == nil,
            isManual() || hosts.contains(host),
            isManual() || ["GET", "HEAD"].contains(action.request.httpMethod ?? "GET"),
            action.targetFrame != nil
        else {
            decisionHandler(.cancel)
            finish(
                AgentError.unavailable(
                    "Navigation refusée. Ouvrez explicitement le site ou prenez la main."))
            return
        }
        decisionHandler(.allow)
    }
    static func fetch(_ request: [String: AgentValue], runtime: URL) async -> [String: AgentValue] {
        do {
            return try await Task.detached {
                let p = Process()
                let input = Pipe()
                let output = Pipe()
                p.executableURL = runtime.appending(path: "node")
                p.arguments = [runtime.appending(path: "fetch.mjs").path]
                p.environment = ["PATH": "/usr/bin:/bin"]
                p.standardInput = input
                p.standardOutput = output
                p.standardError = FileHandle.nullDevice
                try p.run()
                try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return try JSONDecoder().decode([String: AgentValue].self, from: data)
            }.value
        } catch { return ["error": .string(error.localizedDescription)] }
    }
}
