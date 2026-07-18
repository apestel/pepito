import Foundation

public enum CaptureError: Error, Equatable {
    case alreadyRecording
    case notRecording
    case notImplemented(String)
    case permissionDenied(AudioSource)
    case audioHardware(OSStatus)
}

extension CaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: "Un enregistrement est déjà en cours."
        case .notRecording: "Aucun enregistrement en cours."
        case .notImplemented(let message): "Non implémenté : \(message)"
        case .permissionDenied(let source): "Permission refusée pour la source « \(source.rawValue) »."
        case .audioHardware(let status): "Erreur audio système (code \(status))."
        }
    }
}

/// Décrit une session d'enregistrement : dossier de sortie + fichiers par source.
/// Les fichiers séparés (micro/système) permettent la diarisation grossière (CLAUDE.md §3).
public struct RecordingSession: Sendable, Equatable {
    public let id: UUID
    public let directory: URL
    public let sources: Set<AudioSource>

    public init(id: UUID = UUID(), directory: URL, sources: Set<AudioSource>) {
        self.id = id
        self.directory = directory
        self.sources = sources
    }

    public func fileURL(for source: AudioSource) -> URL {
        directory.appending(path: "\(source.rawValue).caf")
    }

    /// Fichiers attendus, ordre déterministe.
    public var expectedFiles: [URL] {
        sources.sorted { $0.rawValue < $1.rawValue }.map(fileURL(for:))
    }
}
