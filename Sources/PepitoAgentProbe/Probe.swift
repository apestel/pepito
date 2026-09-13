import AppCore
import Foundation
import SandboxKit

/// Diagnostic opt-in, sans accès aux données de l'utilisateur.
@main struct Probe {
    static func main() async throws {
        if [3, 5].contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--endpoint-test" {
            var settings = SettingsStore.defaultLocation().load()
            if CommandLine.arguments.count == 5 {
                settings.aiBaseURL = CommandLine.arguments[3]
                settings.aiModel = CommandLine.arguments[4]
                print("Configuration explicite (aucune modification des réglages)")
            } else {
                print("Configuration enregistrée sur disque ; elle peut différer des réglages ouverts dans Pépito")
            }
            print("Test de \(settings.aiModel) sur \(settings.aiBaseURL)")
            try await AppCore.testAgentRuntime(runtime: URL(fileURLWithPath: CommandLine.arguments[2]),settings:settings)
            print("Aller-retour agentique confirmé")
            return
        }
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--browser-test" {
            try await AppCore.testMissionBrowser(
                kernel: URL(fileURLWithPath: CommandLine.arguments[2]),
                root: URL(fileURLWithPath: CommandLine.arguments[3]),
                runtime: URL(fileURLWithPath: CommandLine.arguments[4]))
            print("Navigateur isolé : page publique, capture et arrêt confirmés")
            return
        }
        guard CommandLine.arguments.count == 3 else {
            print("Usage: PepitoAgentProbe <kernel> <cache-directory>")
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let vm = Sandbox(root: root)
        print("Préparation VM Apple sans réseau…")
        do {
            try await vm.start(kernel: URL(fileURLWithPath: CommandLine.arguments[1]))
            print("VM démarrée")
            for (language, code) in [
                ("python", "print(6*7)"), ("javascript", "console.log(6*7)"), ("shell", "printf 42"),
            ] {
                let result = try await vm.script(language: language, code: code)
                guard result.exitCode == 0,
                    result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "42"
                else { throw SandboxError.unavailable("Échec \(language): \(result.output)") }
                print("\(language) : OK")
            }
            let isolated = try await vm.script(
                language: "python",
                code: """
                    import os,socket
                    assert not os.path.exists('/Users')
                    assert not os.path.exists('/var/run/docker.sock')
                    assert not any('TOKEN' in k or 'KEY' in k for k in os.environ)
                    s=socket.socket();s.settimeout(2)
                    try: s.connect(('1.1.1.1',443))
                    except OSError: print('isolated')
                    else: raise AssertionError('network escaped')
                    open('/workspace/result.txt','w').write('42')
                    """)
            guard isolated.exitCode == 0 else { throw SandboxError.unavailable(isolated.output) }
            try FileManager.default.createDirectory(
                at: root.appending(path: "results"), withIntermediateDirectories: true)
            let file = try await vm.copyOut(name: "result.txt", to: root.appending(path: "results"))
            guard try String(contentsOf: file, encoding: .utf8) == "42" else {
                throw SandboxError.unavailable("Export incorrect")
            }
            _ = try await vm.script(language: "shell", code: "ln -s /etc/passwd /workspace/escape")
            do {
                _ = try await vm.copyOut(name: "escape", to: root.appending(path: "results"))
                throw SandboxError.unavailable("Le lien symbolique a été accepté")
            } catch SandboxError.invalidPath {}
            do {
                _ = try await vm.copyOut(name: "/etc/passwd", to: root.appending(path: "results"))
                throw SandboxError.unavailable("Le chemin absolu a été accepté")
            } catch SandboxError.invalidPath {}
            print("Isolation hôte/réseau/secrets, chemins, liens et export : OK")
            await vm.stop()
            print("VM arrêtée")
        } catch {
            await vm.stop()
            throw error
        }
    }
}
