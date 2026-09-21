import Darwin
import Foundation

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
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SandboxError.invalidPath }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            close(fd)
            throw SandboxError.invalidPath
        }
        guard info.st_size <= limit else {
            close(fd)
            throw SandboxError.tooLarge
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw SandboxError.tooLarge }
        return data
    }
}

/// Captured independently so errors never get mixed into the program's output.
public struct SandboxResult: Codable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let duration: Double
    public var output: String { stdout + (stderr.isEmpty ? "" : "\n" + stderr) }
}

/// Persistent scratchpad. Scripts inherit a deny-by-default macOS Seatbelt profile;
/// no network, user-home reads, credentials or writes outside this directory.
public actor Sandbox {
    public let root: URL
    private let runtime: URL
    private var process: Process?
    private var input: Pipe?
    private var ready = false
    public init(root: URL, runtime: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.runtime = runtime
    }
    public func start() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
            FileManager.default.isExecutableFile(atPath: runtime.appending(path: "node").path),
            FileManager.default.fileExists(
                atPath: runtime.appending(path: "script-runner.mjs").path)
        else {
            throw SandboxError.unavailable("Runtime isolé absent. Reconstruisez le bundle Pépito.")
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        ready = true
    }
    public func script(language: String, code: String, timeout: Int = 60_000, network: Bool = false)
        async throws -> SandboxResult
    {
        guard ready, process == nil else {
            throw SandboxError.unavailable("Scratchpad indisponible ou occupé")
        }
        guard code.utf8.count <= 262_144 else { throw SandboxError.tooLarge }
        try Task.checkCancellation()
        let p = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        p.executableURL = runtime.appending(path: "node")
        p.arguments = [runtime.appending(path: "script-runner.mjs").path]
        p.environment = ["PATH": "/usr/bin:/bin"]
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        input = stdin
        defer {
            process = nil
            input = nil
            try? stdin.fileHandleForWriting.close()
        }
        let request =
            try JSONSerialization.data(withJSONObject: [
                "root": root.path, "language": language, "code": code, "timeout_ms": timeout,
                "network": network,
            ]) + Data([10])
        try stdin.fileHandleForWriting.write(contentsOf: request)
        return try await withTaskCancellationHandler {
            let data = await Task.detached {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return data
            }.value
            try Task.checkCancellation()
            guard data.count <= 26 * 1024 * 1024 else { throw SandboxError.tooLarge }
            return try JSONDecoder().decode(SandboxResult.self, from: data)
        } onCancel: {
            // EOF asks the supervisor to kill the entire process group, including descendants.
            try? stdin.fileHandleForWriting.close()
        }
    }
    public func copyIn(file: URL, name: String) throws {
        guard ready else { throw SandboxError.unavailable("Scratchpad indisponible") }
        let data = try WorkspaceFiles.read(
            file.lastPathComponent, in: file.deletingLastPathComponent(), limit: 100 * 1024 * 1024)
        let destination = try WorkspaceFiles.file(name, in: root)
        // Preserve intermediate work across mission resumptions.
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: .atomic)
        }
    }
    public func copyOut(name: String, to directory: URL) throws -> URL {
        guard ready else { throw SandboxError.unavailable("Scratchpad indisponible") }
        let destination = try WorkspaceFiles.file(name, in: directory)
        let data = try WorkspaceFiles.read(name, in: root, limit: 100 * 1024 * 1024)
        try data.write(to: destination, options: .atomic)
        return destination
    }
    public func stop() {
        ready = false
        try? input?.fileHandleForWriting.close()
    }
}
