import Foundation
import AVFoundation

/// Enregistreur micro réel (AVAudioEngine → fichier CAF). Code plateforme : compile et fonctionne
/// à l'exécution avec un vrai périphérique ; non couvert par les tests unitaires (nécessite audio).
public final class MicrophoneRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    public init() {}

    /// Démarre l'enregistrement micro. `onBuffer` (optionnel) reçoit chaque buffer capté, pour
    /// alimenter une transcription live en parallèle de l'écriture fichier (un seul tap).
    public func start(
        writingTo url: URL,
        echoCancellation: Bool = false,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let input = engine.inputNode
        // Annulation d'écho acoustique via le Voice-Processing d'Apple (AEC de FaceTime) : retire de
        // la piste « Moi » la voix des interlocuteurs recaptée par le micro (bleed HP), en amont.
        // ⚠️ VPIO prend possession du micro et le VERROUILLE pour les autres apps (Teams/Zoom ne
        // captent plus rien pendant l'enregistrement) — c'est pourquoi le défaut est l'AEC hors-ligne
        // (mode partageable). Activé seulement si l'utilisateur choisit explicitement l'AEC système.
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            } catch {
                // AEC OS indisponible : on continue sans (repli casque / autre mode).
            }
        }
        let format = input.outputFormat(forBus: 0)
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        self.file = audioFile

        // 4096 frames ≈ 85 ms à 48 kHz : granularité du transcript live. (L'ancien 16384 — 340 ms
        // de latence — datait du débogage du nilError de SpeechAnalyzer, dont la vraie correction
        // est la conversion au format exact + timestamps monotones dans le transcripteur ; la piste
        // système streame des buffers bien plus petits sans problème.)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? audioFile.write(from: buffer)
            onBuffer?(buffer)
        }
        do {
            try engine.start()
        } catch {
            stop() // Retirer le tap même si le moteur n'a pas démarré (prochaine dictée/reprise).
            throw error
        }
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }
}
