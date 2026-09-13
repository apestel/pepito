import AgentKit
import Foundation
import SandboxKit

/// Navigateur dans une VM distincte ; chaque requête HTTP traverse le contrôleur hôte.
@MainActor
final class MissionBrowser {
    struct Result {
        var text: String
        var url: String
        var image: Data?
    }
    private let vm: Sandbox
    private var channel: GuestChannel?
    private var reader: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Result, Error>] = [:]
    private var hosts: Set<String> = []
    var isManual: () -> Bool = { false }
    private var starting = false
    init(root: URL) { vm = Sandbox(root: root) }
    func command(args: [String: AgentValue], kernel: URL, runtime: URL) async throws -> Result {
        guard pending.isEmpty, !starting else { throw AgentError.unavailable("Le navigateur travaille déjà") }
        if let url = args["url"]?.string, args["operation"]?.string == "open" {
            guard let u = URL(string: url), ["https", "http"].contains(u.scheme), let host = u.host else {
                throw AgentError.unavailable("URL HTTP(S) requise")
            }
            hosts.insert(host)
        }
        if channel == nil {
            starting = true
            do {
                try await vm.start(kernel: kernel)
                try await vm.installBrowserRuntime(from: runtime)
                let ch = try await vm.startBrowserWorker()
                channel = ch
                reader = Task {
                    var buffer = Data()
                    do {
                        for await bytes in ch.output {
                            buffer.append(bytes)
                            guard buffer.count <= 16 * 1024 * 1024 else { throw SandboxError.tooLarge }
                            while let i = buffer.firstIndex(of: 10) {
                                let data = buffer.prefix(upTo: i)
                                buffer.removeSubrange(...i)
                                let value = try JSONDecoder().decode([String: AgentValue].self, from: data)
                                if value["type"]?.string == "network" {
                                    var request = value
                                    request["allowedHosts"] = .array(hosts.map(AgentValue.string))
                                    request["manual"] = .bool(isManual())
                                    let response = await Self.fetch(request, runtime: runtime)
                                    var result = response
                                    result["type"] = .string("network_result")
                                    result["id"] = value["id"]
                                    try send(result)
                                } else if value["type"]?.string == "result", let id = value["id"]?.string,
                                    let waiter = pending.removeValue(forKey: id)
                                {
                                    if let error = value["error"]?.string {
                                        waiter.resume(throwing: AgentError.unavailable(error))
                                    } else {
                                        waiter.resume(
                                            returning: Result(
                                                text: value["text"]?.string ?? "",
                                                url: value["url"]?.string ?? "",
                                                image: value["image"]?.string.flatMap {
                                                    Data(base64Encoded: $0)
                                                }))
                                    }
                                }
                            }
                        }
                        throw AgentError.unavailable("Navigateur arrêté")
                    } catch { fail(error) }
                }
                starting = false
            } catch {
                starting = false
                await stop()
                throw error
            }
        }
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try send(["type": .string("command"), "id": .string(id), "arguments": .object(args)])
                } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
                Task {
                    try? await Task.sleep(for: .seconds(45))
                    if let waiter = pending.removeValue(forKey: id) {
                        waiter.resume(
                            throwing: AgentError.unavailable(
                                "Le navigateur n'a pas répondu ; son résultat est incertain."))
                        await stop()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in await self.stop() }
        }
    }
    private func send(_ value: [String: AgentValue]) throws {
        guard let channel else { throw AgentError.unavailable("Navigateur arrêté") }
        var data = try JSONEncoder().encode(value)
        data.append(10)
        channel.send(data)
    }
    private func fail(_ error: any Error) {
        let waiters = pending.values
        pending.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }
    func stop() async {
        fail(CancellationError())
        reader?.cancel()
        reader = nil
        try? channel?.close()
        channel = nil
        await vm.stop()
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
