import Foundation
import AVFoundation
import os

/// Contrôleur de capture réel combinant micro (AVAudioEngine) et sortie système (Core Audio
/// process tap en priorité, ScreenCaptureKit en repli automatique) vers une `RecordingSession`
/// (fichiers séparés). Isolé MainActor pour un usage UI direct.
@MainActor
public final class CaptureController {
    public private(set) var session: RecordingSession?
    public private(set) var isRecording = false
    /// Sources réellement démarrées (une source sans permission est ignorée, pas fatale).
    public private(set) var startedSources: Set<AudioSource> = []

    private let microphone = MicrophoneRecorder()
    private var systemRecorder: (any SystemAudioRecording)?
    private let log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
    }

    /// Démarre les sources demandées dans `directory`. Chaque source est indépendante : on ignore
    /// celles dont la permission manque et on ne lève une erreur que si aucune n'a démarré.
    @discardableResult
    public func start(
        sources: Set<AudioSource>,
        in directory: URL,
        microphoneEchoCancellation: Bool = false,
        systemAudioBundleID: String? = nil,
        onMicBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        onSystemBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) async throws -> RecordingSession {
        guard !isRecording else { throw CaptureError.alreadyRecording }
        let session = RecordingSession(directory: directory, sources: sources)

        var started: Set<AudioSource> = []
        var lastError: Error?

        if sources.contains(.microphone) {
            do {
                try microphone.start(
                    writingTo: session.fileURL(for: .microphone),
                    echoCancellation: microphoneEchoCancellation,
                    onBuffer: onMicBuffer
                )
                started.insert(.microphone)
            } catch { lastError = error }
        }
        if sources.contains(.system) {
            do {
                try await startSystemRecorder(
                    writingTo: session.fileURL(for: .system),
                    bundleID: systemAudioBundleID,
                    onBuffer: onSystemBuffer
                )
                started.insert(.system)
            } catch {
                lastError = error
                // Erreur autrefois avalée en silence : la source système est ignorée mais on trace
                // pourquoi (permission audio système / macOS), sinon on croit capter alors que non.
                log("Capture système non démarrée : \(error.localizedDescription)")
            }
        }

        guard !started.isEmpty else {
            throw lastError ?? CaptureError.notRecording
        }

        self.session = session
        self.startedSources = started
        isRecording = true
        return session
    }

    /// Démarre la capture système : **Core Audio process tap d'abord** (permission « audio
    /// système » seulement — pas d'enregistrement d'écran, ni rappels TCC, ni indicateur, ni flux
    /// vidéo factice), ScreenCaptureKit en repli — immédiat si le tap échoue au démarrage, différé
    /// (watchdog) s'il ne cadence pas de buffers, panne observée sur certains matériels.
    private func startSystemRecorder(
        writingTo url: URL,
        bundleID: String?,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) async throws {
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        let counting: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
            delivered.withLock { $0 += 1 }
            onBuffer?(buffer)
        }
        do {
            let tap = CoreAudioTapSystemAudioRecorder(log: log)
            try await tap.start(writingTo: url, bundleID: bundleID, onBuffer: counting)
            systemRecorder = tap
            watchTap(tap, delivered: delivered, url: url, bundleID: bundleID, onBuffer: onBuffer)
        } catch {
            log("Tap Core Audio indisponible (\(error.localizedDescription)) — repli ScreenCaptureKit.")
            let sck = ScreenCaptureKitSystemAudioRecorder(log: log)
            try await sck.start(writingTo: url, bundleID: bundleID, onBuffer: onBuffer)
            systemRecorder = sck
        }
    }

    /// Un IOProc sain délivre ~90 buffers/s ; la panne connue en délivrait un seul. Si le tap ne
    /// cadence pas après 3 s, bascule sur ScreenCaptureKit dans le même fichier (que SCK crée
    /// paresseusement au premier buffer, donc réécrit proprement) sans interrompre l'enregistrement.
    private func watchTap(
        _ tap: CoreAudioTapSystemAudioRecorder,
        delivered: OSAllocatedUnfairLock<Int>,
        url: URL,
        bundleID: String?,
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.isRecording, (self.systemRecorder as AnyObject) === tap else { return }
            let count = delivered.withLock { $0 }
            guard count < 30 else { return }
            self.log("Tap Core Audio muet (\(count) buffer(s) en 3 s) — repli ScreenCaptureKit.")
            try? await tap.stop()
            let sck = ScreenCaptureKitSystemAudioRecorder(log: self.log)
            do {
                try await sck.start(writingTo: url, bundleID: bundleID, onBuffer: onBuffer)
                self.systemRecorder = sck
            } catch {
                self.systemRecorder = nil
                self.log("Repli ScreenCaptureKit échoué : \(error.localizedDescription)")
            }
        }
    }

    public func stop() async throws {
        guard isRecording else { throw CaptureError.notRecording }
        microphone.stop()
        try? await systemRecorder?.stop()
        systemRecorder = nil
        isRecording = false
    }
}
