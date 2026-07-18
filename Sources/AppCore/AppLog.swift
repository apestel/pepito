import Foundation
import os

/// Journal fichier consultable par l'utilisateur, en plus d'`os.Logger`.
/// Écrit dans `~/Library/Application Support/Pepito/pepito.log`.
public struct AppLog: Sendable {
    public static let shared = AppLog()
    public let fileURL: URL

    private static let queue = DispatchQueue(label: "com.pepito.filelog")
    private let osLog = Log.logger("App")

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = base.appending(path: "Pepito/pepito.log")
    }

    public func log(_ message: String, level: String = "INFO") {
        osLog.log("[\(level, privacy: .public)] \(message, privacy: .public)")
        let line = "\(Self.timestamp()) [\(level)] \(message)\n"
        let url = fileURL
        Self.queue.async {
            guard let data = line.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Détail complet d'une erreur (domaine + code NSError, en plus du message).
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) code=\(ns.code) — \(ns.localizedDescription) | \(String(describing: error))"
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
