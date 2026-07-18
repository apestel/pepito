import Foundation

/// Transcription on-device via Apple SpeechAnalyzer/SpeechTranscriber. Implémentation en Phase 2.
public enum TranscriptionKit {
    public static let moduleName = "TranscriptionKit"
}

/// Segment de transcript horodaté. `source` permet une diarisation grossière (micro vs système).
public struct TranscriptSegment: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var confidence: Double
    public var speakerLabel: String?

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Double = 1.0,
        speakerLabel: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.speakerLabel = speakerLabel
    }
}

/// Contrat de transcription, mockable (le vrai backend enveloppera `SpeechAnalyzer`).
public protocol Transcriber: Sendable {
    /// Transcrit un fichier audio en segments finalisés.
    func transcribeFile(at url: URL, locale: Locale) async throws -> [TranscriptSegment]
}
