import Foundation
import AVFoundation
import os

/// Un état de transcript live : les segments finalisés (avec timing, pour fusion chronologique
/// entre sources) + le fragment volatil en cours de parole.
public struct LiveTranscriptUpdate: Sendable, Equatable {
    public var finalizedSegments: [TranscriptSegment]
    public var volatileText: String
    /// Échec du flux live, affichable par les consommateurs de dictée.
    public var errorMessage: String?

    public init(finalizedSegments: [TranscriptSegment], volatileText: String, errorMessage: String? = nil) {
        self.finalizedSegments = finalizedSegments
        self.volatileText = volatileText
        self.errorMessage = errorMessage
    }
}

/// Transcription en continu : on démarre, on pousse des buffers audio captés, on lit des mises à
/// jour au fil de l'eau, puis on finalise. `finish()` renvoie les segments **finalisés** (avec
/// timing) qui constituent le transcript de référence — évitant toute re-transcription.
public protocol LiveTranscribing: AnyObject, Sendable {
    var updates: AsyncStream<LiveTranscriptUpdate> { get }
    func start(locale: Locale) async throws
    /// Fournit un buffer audio (appelé depuis le thread de capture).
    func ingest(_ buffer: AVAudioPCMBuffer)
    /// Finalise et renvoie les segments finalisés collectés pendant l'enregistrement.
    func finish() async -> [TranscriptSegment]
}

/// Implémentation factice pour tests/previews : émet ce qu'on lui donne via `emit`.
public final class MockLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    public let updates: AsyncStream<LiveTranscriptUpdate>
    private let continuation: AsyncStream<LiveTranscriptUpdate>.Continuation
    private let segments = OSAllocatedUnfairLock(initialState: [TranscriptSegment]())

    public init() {
        (updates, continuation) = AsyncStream.makeStream()
    }

    public func start(locale: Locale) async throws {}
    public func ingest(_ buffer: AVAudioPCMBuffer) {}

    public func finish() async -> [TranscriptSegment] {
        continuation.finish()
        return segments.withLock { $0 }
    }

    /// Aide de test : simule un segment finalisé (collecte + mise à jour d'affichage).
    public func emit(finalized: String, at start: TimeInterval = 0, volatile: String = "") {
        let all = segments.withLock { segs -> [TranscriptSegment] in
            if !finalized.isEmpty {
                segs.append(TranscriptSegment(start: start, end: start, text: finalized))
            }
            return segs
        }
        continuation.yield(LiveTranscriptUpdate(finalizedSegments: all, volatileText: volatile))
    }
}
