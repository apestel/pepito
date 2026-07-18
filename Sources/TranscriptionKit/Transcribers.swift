import Foundation
import Speech

public enum TranscriptionError: Error, Equatable {
    case notImplemented(String)
    case modelUnavailable(localeIdentifier: String)
    case permissionDenied
    case audioFormatUnavailable
}

extension TranscriptionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notImplemented(let message):
            "Transcription non implémentée : \(message)"
        case .modelUnavailable(let identifier):
            "Modèle de transcription indisponible pour la langue « \(identifier) ». Choisis une langue supportée dans les Réglages."
        case .permissionDenied:
            "Accès à la reconnaissance vocale refusé (autorise Pépito dans Réglages Système › Confidentialité)."
        case .audioFormatUnavailable:
            "Format audio incompatible avec la transcription."
        }
    }
}

/// Transcripteur factice renvoyant des segments prédéfinis (tests, previews).
public struct MockTranscriber: Transcriber {
    public let segments: [TranscriptSegment]
    public init(segments: [TranscriptSegment]) { self.segments = segments }

    public func transcribeFile(at url: URL, locale: Locale) async throws -> [TranscriptSegment] {
        segments
    }
}
