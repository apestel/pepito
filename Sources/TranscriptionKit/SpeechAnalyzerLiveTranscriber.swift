import Foundation
import Speech
import AVFoundation
import CoreMedia
import os

/// Transcription live via SpeechAnalyzer en streaming (résultats volatils + finalisés).
/// Alimenté par les buffers captés pendant l'enregistrement. Les segments **finalisés** collectés
/// constituent le transcript de référence (récupérés par `finish()`) — pas de re-transcription.
///
/// Corrections du `nilError` de `start(inputSequence:)` : buffers convertis au **format exact** de
/// l'analyseur et `bufferStartTime` **monotone** (voir Apple DevForums thread 818005).
public final class SpeechAnalyzerLiveTranscriber: LiveTranscribing, @unchecked Sendable {
    public let updates: AsyncStream<LiveTranscriptUpdate>
    private let updatesContinuation: AsyncStream<LiveTranscriptUpdate>.Continuation

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private struct State {
        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        var analyzer: SpeechAnalyzer?
        var converter: AVAudioConverter?
        var analyzerFormat: AVAudioFormat?
        var resultsTask: Task<Void, Never>?
        var sampleTime: AVAudioFramePosition = 0
        var finalizedSegments: [TranscriptSegment] = []
    }

    private let log = Logger(subsystem: "com.pepito.app", category: "LiveTranscription")
    private let logSink: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.logSink = log
        (updates, updatesContinuation) = AsyncStream.makeStream()
    }

    private func step(_ message: String) {
        log.info("\(message, privacy: .public)")
        logSink(message)
    }

    public func start(locale: Locale) async throws {
        try await SpeechAnalyzerTranscriber.requestAuthorization(log: step)
        // `.fastResults` : hypothèses volatiles rapprochées (latence d'affichage), au prix d'une
        // précision moindre possible — le transcript de référence reste les segments finalisés.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        try await SpeechAnalyzerTranscriber.ensureModelInstalled(for: transcriber, locale: locale, log: step)

        // Priorité haute + modèle gardé chargé entre deux enregistrements : les premiers mots
        // d'une réunion n'attendent plus le chargement du modèle.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        step("Live prêt (format=\(format.map { "\(Int($0.sampleRate))Hz" } ?? "défaut"))…")

        // Consommation des résultats → collecte des segments finalisés + mises à jour d'affichage.
        let resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    let update = self.state.withLockUnchecked { st -> LiveTranscriptUpdate in
                        if result.isFinal {
                            if !text.isEmpty {
                                let start = result.range.start.seconds
                                let end = result.range.end.seconds
                                st.finalizedSegments.append(TranscriptSegment(
                                    start: start.isFinite ? start : 0,
                                    end: end.isFinite ? end : (start.isFinite ? start : 0),
                                    text: text
                                ))
                            }
                            return LiveTranscriptUpdate(finalizedSegments: st.finalizedSegments, volatileText: "")
                        } else {
                            return LiveTranscriptUpdate(finalizedSegments: st.finalizedSegments, volatileText: text)
                        }
                    }
                    self.updatesContinuation.yield(update)
                }
            } catch {
                self.step("Erreur résultats live : \(error)")
            }
        }

        state.withLockUnchecked { st in
            st.inputContinuation = continuation
            st.analyzer = analyzer
            st.analyzerFormat = format
            st.resultsTask = resultsTask
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Convertit chaque buffer au **format exact** de l'analyseur (copie possédée) et le met en file
    /// avec un `bufferStartTime` monotone.
    public func ingest(_ buffer: AVAudioPCMBuffer) {
        state.withLockUnchecked { st in
            guard let continuation = st.inputContinuation else { return }
            let target = st.analyzerFormat ?? buffer.format
            if st.converter?.inputFormat != buffer.format || st.converter?.outputFormat != target {
                st.converter = AVAudioConverter(from: buffer.format, to: target)
            }
            guard let converter = st.converter,
                  let converted = Self.convert(buffer, using: converter, to: target) else { return }

            let startTime = CMTime(value: st.sampleTime, timescale: CMTimeScale(target.sampleRate))
            st.sampleTime += AVAudioFramePosition(converted.frameLength)
            continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
        }
    }

    public func finish() async -> [TranscriptSegment] {
        let (analyzer, task) = state.withLockUnchecked { st -> (SpeechAnalyzer?, Task<Void, Never>?) in
            st.inputContinuation?.finish()
            st.inputContinuation = nil
            return (st.analyzer, st.resultsTask)
        }
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await task?.value // attend que les derniers résultats soient collectés
        updatesContinuation.finish()
        return state.withLockUnchecked { $0.finalizedSegments }
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let pending = LivePendingBuffer(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, statusPtr in
            guard let next = pending.take() else {
                statusPtr.pointee = .noDataNow
                return nil
            }
            statusPtr.pointee = .haveData
            return next
        }
        return error == nil ? output : nil
    }
}

/// Fournit un buffer une seule fois au bloc @Sendable du convertisseur.
private final class LivePendingBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}
