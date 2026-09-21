import AgentKit
import Foundation
import SandboxKit

extension AppCore {
    /// Test réel du protocole d'outils, sans fournir de donnée métier au modèle.
    @MainActor public static func testAgentRuntime(runtime: URL, settings: Settings? = nil)
        async throws
    {
        let settings = settings ?? SettingsStore.defaultLocation().load()
        let token = try KeychainTokenStore().token(for: "default") ?? ""
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let process = AgentProcess()
        defer { process.stop() }
        let events = try process.start(
            runtime: runtime, node: runtime.appending(path: "node"), directory: dir)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { process.stop() }
        }
        defer { timeout.cancel() }
        try process.send([
            "type": .string("start"), "endpoint": .string(settings.aiBaseURL),
            "model": .string(settings.aiModel), "token": .string(token),
            "budget": .number(Double(settings.aiInputTokenBudget)),
            "sessionDirectory": .string(dir.path),
            "systemPrompt": .string(
                "Tu testes un protocole. Appelle probe avec pepito-probe puis confirme."),
            "probe": .bool(true),
        ])
        var called = false
        for try await event in events {
            switch event.type {
            case "ready":
                try process.send([
                    "type": .string("prompt"),
                    "text": .string(
                        "Appelle probe avec la valeur pepito-probe, puis confirme la valeur renvoyée."
                    ),
                ])
            case "tool":
                guard event.name == "probe", event.arguments?["value"]?.string == "pepito-probe",
                    let id = event.id
                else {
                    throw AgentError.protocolError(
                        "Le modèle n'a pas respecté le protocole d'outil.")
                }
                called = true
                try process.send([
                    "type": .string("tool_result"), "id": .string(id),
                    "text": .string("pepito-probe"),
                ])
            case "error": throw AgentError.unavailable(event.text ?? "Erreur IA")
            case "done":
                guard called else {
                    throw AgentError.unavailable("Le modèle n'a pas appelé l'outil.")
                }
                return
            default: break
            }
        }
        throw AgentError.unavailable("Test interrompu ou délai dépassé.")
    }
}

extension AppCore {
    /// Diagnostic du navigateur isolé sur une page publique sans transaction.
    @MainActor public static func testMissionBrowser(root: URL) async throws {
        let browser = MissionBrowser()
        do {
            let result = try await browser.command(
                args: ["operation": .string("open"), "url": .string("https://example.com")])
            guard result.text.contains("Example Domain"), let image = result.image, !image.isEmpty
            else {
                throw AgentError.unavailable("Page ou capture navigateur manquante")
            }
            try image.write(to: root.appending(path: "browser.jpg"))
            browser.stop()
        } catch {
            browser.stop()
            throw error
        }
    }
}
