import Foundation

/// Valeur JSON du pont, sans exposer les objets non-Sendable de Foundation.
public enum AgentValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AgentValue])
    case array([AgentValue])
    case null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode([String: AgentValue].self) {
            self = .object(v)
        } else {
            self = .array(try c.decode([AgentValue].self))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
}

public struct AgentEvent: Codable, Sendable {
    public var type: String
    public var id: String?
    public var name: String?
    public var text: String?
    public var arguments: [String: AgentValue]?
}

/// Découpe exclusivement sur LF ; préserve les caractères UTF-8 fragmentés et U+2028.
public struct AgentFramer: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [AgentEvent] {
        buffer.append(bytes)
        var events: [AgentEvent] = []
        while let end = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: end) <= 2_097_152 else {
                throw AgentError.protocolError("Message trop volumineux")
            }
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            if !line.isEmpty { events.append(try JSONDecoder().decode(AgentEvent.self, from: line)) }
        }
        guard buffer.count <= 2_097_152 else { throw AgentError.protocolError("Message trop volumineux") }
        return events
    }
    public func finish() throws {
        guard buffer.isEmpty else { throw AgentError.protocolError("Message JSONL incomplet") }
    }
}

public enum AgentError: LocalizedError {
    case protocolError(String)
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .protocolError(let s), .unavailable(let s): s
        }
    }
}

/// Processus Pi privé à une mission. Aucun shell ni environnement utilisateur hérité.
@MainActor
public final class AgentProcess {
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    public init() {}

    public func start(runtime: URL, node: URL, directory: URL) throws -> AsyncThrowingStream<
        AgentEvent, Error
    > {
        guard process == nil else { throw AgentError.unavailable("Un agent travaille déjà") }
        guard FileManager.default.isExecutableFile(atPath: node.path),
            FileManager.default.fileExists(atPath: runtime.appending(path: "bridge.mjs").path)
        else {
            throw AgentError.unavailable("Moteur Pi absent du bundle. Relancez build-app.sh.")
        }
        let p = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        p.executableURL = node
        p.arguments = [runtime.appending(path: "bridge.mjs").path]
        p.currentDirectoryURL = directory
        p.environment = [
            "HOME": directory.path, "TMPDIR": directory.path, "PATH": "/usr/bin:/bin", "LANG": "fr_FR.UTF-8",
        ]
        p.standardInput = stdin
        p.standardOutput = stdout
        // Les erreurs structurées passent par stdout ; stderr peut contenir des données du fournisseur.
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
        let (stream, continuation) = AsyncThrowingStream<AgentEvent, Error>.makeStream()
        let handle = stdout.fileHandleForReading
        reader = Task.detached {
            var framer = AgentFramer()
            do {
                while !Task.isCancelled {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    for event in try framer.append(data) { continuation.yield(event) }
                }
                try framer.finish()
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
            try? handle.close()
        }
        return stream
    }
    public func send(_ command: [String: AgentValue]) throws {
        guard let input else { throw AgentError.unavailable("Agent arrêté") }
        var data = try JSONEncoder().encode(command)
        data.append(10)
        try input.write(contentsOf: data)
    }
    public func stop() {
        try? input?.close()
        input = nil
        if let process, process.isRunning { process.terminate() }
        let old = process
        Task {
            try? await Task.sleep(for: .seconds(2))
            if let old, old.isRunning { kill(old.processIdentifier, SIGKILL) }
        }
        reader?.cancel()
        reader = nil
        process = nil
    }
}
