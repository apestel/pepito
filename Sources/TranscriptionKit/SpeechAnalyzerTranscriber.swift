import Foundation
import Speech
import AVFoundation
import CoreMedia
import os

private let transcriptionLog = Logger(subsystem: "com.pepito.app", category: "Transcription")

/// Transcripteur fichier basé sur Apple `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+, on-device).
/// Utilise l'API dédiée `start(inputAudioFile:finishAfterFile:)` : l'analyseur lit le fichier et gère
/// lui-même la conversion de format (bien plus fiable que d'alimenter des buffers à la main).
/// Sert de **repli** quand le transcript live n'a rien produit.
public struct SpeechAnalyzerTranscriber: Transcriber {
    let logSink: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.logSink = log
    }

    private func step(_ message: String) {
        transcriptionLog.info("\(message, privacy: .public)")
        logSink(message)
    }

    public func transcribeFile(at url: URL, locale: Locale) async throws -> [TranscriptSegment] {
        // Ouvrir le fichier d'abord : inutile de demander l'autorisation Speech (une alerte système)
        // pour échouer ensuite sur un fichier illisible.
        let file = try AVAudioFile(forReading: url)

        try await Self.requestAuthorization(log: step)
        step("Autorisation Speech OK, préparation…")

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await Self.ensureModelInstalled(for: transcriber, locale: locale, log: step)

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collecte concurrente des résultats.
        let resultsTask = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(
                    start: result.range.start.seconds.isFinite ? result.range.start.seconds : 0,
                    end: result.range.end.seconds.isFinite ? result.range.end.seconds : result.range.start.seconds,
                    text: text
                ))
            }
            return segments
        }

        step("Analyse du fichier (\(Int(file.length)) frames)…")
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let segments = try await resultsTask.value
        step("Transcription fichier terminée : \(segments.count) segment(s)")
        return segments
    }

    /// Demande l'autorisation de reconnaissance vocale (requise par le framework Speech).
    static func requestAuthorization(log: @Sendable (String) -> Void) async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            log("Demande d'autorisation Speech…")
            let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
            guard status == .authorized else {
                log("Autorisation Speech refusée (statut \(status.rawValue))")
                throw TranscriptionError.permissionDenied
            }
        default:
            log("Autorisation Speech non accordée (Réglages Système › Confidentialité › Reconnaissance vocale)")
            throw TranscriptionError.permissionDenied
        }
    }

    // MARK: - Modèle de langue

    static func ensureModelInstalled(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        log: @Sendable (String) -> Void = { _ in }
    ) async throws {
        let target = locale.identifier(.bcp47)
        let language = locale.language.languageCode?.identifier

        let supported = await SpeechTranscriber.supportedLocales
        log("Locales supportées : \(supported.map { $0.identifier(.bcp47) }.joined(separator: ", "))")

        func matches(_ candidate: Locale) -> Bool {
            candidate.identifier(.bcp47) == target
                || (language != nil && candidate.language.languageCode?.identifier == language)
        }

        guard supported.contains(where: matches) else {
            throw TranscriptionError.modelUnavailable(localeIdentifier: locale.identifier)
        }

        let installed = await SpeechTranscriber.installedLocales
        log("Locales installées : \(installed.map { $0.identifier(.bcp47) }.joined(separator: ", "))")
        if installed.contains(where: matches) { return }

        log("Téléchargement du modèle pour \(target)…")
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
            log("Modèle de transcription installé")
        } else {
            log("Aucune installation de modèle proposée (déjà disponible ?)")
        }
    }
}
