import Containerization
import Foundation
import Synchronization

public enum SandboxError: LocalizedError {
    case unavailable(String)
    case invalidPath, tooLarge
    public var errorDescription: String? {
        switch self {
        case .unavailable(let s): s
        case .invalidPath: "Chemin refusé : fichier simple requis, sans lien symbolique."
        case .tooLarge: "Fichier ou résultat trop volumineux."
        }
    }
}

/// Résout uniquement un fichier directement dans le dossier autorisé ; jamais un lien.
public enum WorkspaceFiles {
    public static func file(_ name: String, in root: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
            !name.contains("\0"), name.utf8.count <= 240
        else { throw SandboxError.invalidPath }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = base.appendingPathComponent(name)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
            attrs[.type] as? FileAttributeType != .typeRegular
        {
            throw SandboxError.invalidPath
        }
        guard file.resolvingSymlinksInPath().deletingLastPathComponent().path == base.path else {
            throw SandboxError.invalidPath
        }
        return file
    }
    public static func read(_ name: String, in root: URL, limit: Int = 1_048_576) throws -> Data {
        let file = try file(name, in: root)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw SandboxError.tooLarge }
        return data
    }
}

public struct SandboxResult: Sendable {
    public let output: String
    public let exitCode: Int32
}

final class OutputWriter: Writer {
    private let content = Mutex(Data())
    func write(_ data: Data) throws {
        try content.withLock { value in
            guard value.count + data.count <= 4_194_304 else { throw SandboxError.tooLarge }
            value.append(data)
        }
    }
    func close() throws {}
    var text: String { content.withLock { String(decoding: $0, as: UTF8.self) } }
}

/// VM Linux privée : pas d'interface réseau, aucun partage virtiofs, aucun secret de l'hôte.
public actor Sandbox {
    private var container: LinuxContainer?
    private var manager: ContainerManager?
    private var id: String?
    private var generation = 0
    public let root: URL
    public static let initImage =
        "ghcr.io/apple/containerization/vminit@sha256:aa6ab59d0938f7fadb54ac27e80959bdd2f1dafa8050011086d5f8ab1350fd6c"
    public static let workloadImage =
        "mcr.microsoft.com/playwright@sha256:6446946a1d9fd62d9ae501312a2d76a43ee688542b21622056a372959b65d63d"
    public init(root: URL) { self.root = root }

    public func start(kernel: URL) async throws {
        guard container == nil else { return }
        generation += 1
        let currentGeneration = generation
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: kernel.path) else {
            throw SandboxError.unavailable(
                "Noyau Linux absent du bundle. Reconstruisez l’application avec build-app.sh.")
        }
        var manager = try await ContainerManager(
            kernel: Kernel(path: kernel, platform: .linuxArm),
            initfsReference: Self.initImage, root: root.appending(path: "images"), network: nil)
        let id = "pepito-" + UUID().uuidString.lowercased()
        let vm = try await manager.create(
            id, reference: Self.workloadImage, rootfsSizeInBytes: 8 * 1024 * 1024 * 1024,
            networking: false
        ) { config in
            config.cpus = 2
            config.memoryInBytes = 2 * 1024 * 1024 * 1024
            config.process.arguments = ["/bin/sleep", "infinity"]
            config.process.environmentVariables = ["PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/tmp"]
            config.process.noNewPrivileges = true
        }
        guard generation == currentGeneration, !Task.isCancelled else {
            try? manager.delete(id)
            throw CancellationError()
        }
        self.manager = manager
        self.id = id
        self.container = vm
        do {
            try await vm.create()
            try await vm.start()
            _ = try await execute(arguments: ["/bin/mkdir", "-p", "/workspace"], timeout: 20)
        } catch {
            await stop()
            throw error
        }
    }
    public func execute(arguments: [String], timeout: Int64 = 60) async throws -> SandboxResult {
        guard let container else {
            throw SandboxError.unavailable("VM indisponible ; exécution sur le Mac interdite.")
        }
        try Task.checkCancellation()
        let writer = OutputWriter()
        let process = try await container.exec(UUID().uuidString) { config in
            config.arguments = arguments
            config.workingDirectory = "/workspace"
            config.environmentVariables = ["PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/tmp"]
            config.noNewPrivileges = true
            config.stdout = writer
            config.stderr = writer
        }
        try await process.start()
        do {
            let result = try await withTaskCancellationHandler {
                try await process.wait(timeoutInSeconds: timeout)
            } onCancel: {
                Task { try? await container.stop() }
            }
            return SandboxResult(output: writer.text, exitCode: result.exitCode)
        } catch {
            // Une commande peut avoir créé des descendants ; arrêter toute la VM.
            await stop()
            throw error
        }
    }
    public func script(language: String, code: String) async throws -> SandboxResult {
        guard code.utf8.count <= 262_144 else { throw SandboxError.tooLarge }
        let arguments: [String]
        switch language {
        case "python": arguments = ["/usr/bin/python3", "-c", code]
        case "javascript": arguments = ["/usr/bin/node", "-e", code]
        case "shell": arguments = ["/bin/bash", "-c", code]
        default: throw SandboxError.unavailable("Langage inconnu")
        }
        return try await execute(arguments: arguments)
    }
    public func copyIn(file: URL, name: String) async throws {
        guard let container else { throw SandboxError.unavailable("VM arrêtée") }
        _ = try WorkspaceFiles.file(name, in: root)
        let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true else {
            throw SandboxError.invalidPath
        }
        guard (attrs.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw SandboxError.tooLarge }
        try await container.copyIn(from: file, to: URL(fileURLWithPath: "/workspace/" + name))
    }
    public func copyOut(name: String, to directory: URL) async throws -> URL {
        guard let container else { throw SandboxError.unavailable("VM arrêtée") }
        let destination = try WorkspaceFiles.file(name, in: directory)
        // Lire un fichier régulier via Python : pas d'extraction d'archive fournie par le guest.
        let code =
            "import os,stat,base64,sys; p='/workspace/'+sys.argv[1]; f=os.open(p,os.O_RDONLY|os.O_NOFOLLOW); s=os.fstat(f); assert stat.S_ISREG(s.st_mode) and s.st_size<=1048576; print(base64.b64encode(os.read(f,1048577)).decode())"
        let result = try await execute(arguments: ["/usr/bin/python3", "-c", code, name])
        guard result.exitCode == 0,
            let data = Data(base64Encoded: result.output.trimmingCharacters(in: .whitespacesAndNewlines)),
            data.count <= 1_048_576
        else {
            throw SandboxError.invalidPath
        }
        _ = container
        try data.write(to: destination, options: .atomic)
        return destination
    }
    public func stop() async {
        generation += 1
        if let container { try? await container.stop() }
        if var manager, let id { try? manager.delete(id) }
        container = nil
        manager = nil
        id = nil
    }
}

/// Entrée/sortie d'un programme de confiance embarqué dans la VM navigateur.
public final class GuestChannel: ReaderStream, Writer {
    public let output: AsyncStream<Data>
    private let input: AsyncStream<Data>
    private let inputContinuation: AsyncStream<Data>.Continuation
    private let outputContinuation: AsyncStream<Data>.Continuation
    public init() {
        let (i, ic) = AsyncStream<Data>.makeStream()
        input = i
        inputContinuation = ic
        let (o, oc) = AsyncStream<Data>.makeStream()
        output = o
        outputContinuation = oc
    }
    public func stream() -> AsyncStream<Data> { input }
    public func write(_ data: Data) throws { outputContinuation.yield(data) }
    public func send(_ data: Data) { inputContinuation.yield(data) }
    public func close() throws {
        inputContinuation.finish()
        outputContinuation.finish()
    }
}

extension Sandbox {
    public func installBrowserRuntime(from runtime: URL) async throws {
        guard let container else { throw SandboxError.unavailable("VM indisponible") }
        // Sources fixes issues du bundle signé, jamais de chemin fourni par le modèle.
        try await container.copyIn(
            from: runtime.appending(path: "browser.mjs"), to: URL(fileURLWithPath: "/workspace/browser.mjs"))
        try await container.copyIn(
            from: runtime.appending(path: "node_modules/playwright-core"),
            to: URL(fileURLWithPath: "/workspace/playwright-core"))
    }
    public func startBrowserWorker() async throws -> GuestChannel {
        guard let container else { throw SandboxError.unavailable("VM indisponible") }
        let channel = GuestChannel()
        let process = try await container.exec(UUID().uuidString) { config in
            config.arguments = ["/usr/bin/node", "/workspace/browser.mjs"]
            config.environmentVariables = [
                "PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/tmp", "PLAYWRIGHT_BROWSERS_PATH=/ms-playwright",
            ]
            config.workingDirectory = "/workspace"
            config.stdin = channel
            config.stdout = channel
        }
        try await process.start()
        Task {
            _ = try? await process.wait()
            try? channel.close()
        }
        return channel
    }
}
