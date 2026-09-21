import AppCore
import Foundation
import SandboxKit

/// Diagnostic opt-in, sans accès aux données de l'utilisateur.
@main struct Probe {
    static func main() async throws {
        if [3, 5].contains(CommandLine.arguments.count),
            CommandLine.arguments[1] == "--endpoint-test"
        {
            var settings = SettingsStore.defaultLocation().load()
            if CommandLine.arguments.count == 5 {
                settings.aiBaseURL = CommandLine.arguments[3]
                settings.aiModel = CommandLine.arguments[4]
                print("Configuration explicite (aucune modification des réglages)")
            } else {
                print(
                    "Configuration enregistrée sur disque ; elle peut différer des réglages ouverts dans Pépito"
                )
            }
            print("Test de \(settings.aiModel) sur \(settings.aiBaseURL)")
            try await AppCore.testAgentRuntime(
                runtime: URL(fileURLWithPath: CommandLine.arguments[2]), settings: settings)
            print("Aller-retour agentique confirmé")
            return
        }
        guard CommandLine.arguments.count == 3 else {
            print("Usage: PepitoAgentProbe <AgentRuntime> <scratchpad>")
            return
        }
        let sandbox = Sandbox(
            root: URL(fileURLWithPath: CommandLine.arguments[2]),
            runtime: URL(fileURLWithPath: CommandLine.arguments[1]))
        try await sandbox.start()
        for (language, code) in [
            ("python", "print(6*7)"), ("javascript", "console.log(6*7)"), ("shell", "printf 42"),
        ] {
            let result = try await sandbox.script(language: language, code: code)
            guard result.exitCode == 0,
                result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "42"
            else { throw SandboxError.unavailable("Échec \(language): \(result.output)") }
            print("\(language) : OK")
        }
        await sandbox.stop()
    }
}
