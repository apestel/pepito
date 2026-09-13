import Foundation
import Observation
import AVFoundation
import CaptureKit
import TranscriptionKit

/// Dictée locale et explicite de consignes. Le texte tapé reste en préfixe ; les hypothèses
/// volatiles sont remplacées (jamais ajoutées plusieurs fois) jusqu'à la finalisation.
@MainActor
@Observable
public final class InstructionDictation {
    public enum Phase: Equatable { case idle, starting, recording, stopping }
    public var text = ""
    public private(set) var phase: Phase = .idle
    public private(set) var errorMessage: String?
    public var isActive: Bool { phase != .idle }

    private let capture: any AudioCapturing
    private let makeTranscriber: @Sendable () -> any LiveTranscribing
    private let requestPermission: @Sendable () async -> Bool
    private let temporaryRoot: URL
    private var live: (any LiveTranscribing)?
    private var startup: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var stoppingTask: Task<Void, Never>?
    private var directory: URL?
    private var prefix = ""
    private var sessionID: UUID?

    public init(
        capture: (any AudioCapturing)? = nil,
        transcriberFactory: @escaping @Sendable () -> any LiveTranscribing = { SpeechAnalyzerLiveTranscriber() },
        requestPermission: @escaping @Sendable () async -> Bool = {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: true
            case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
            default: false
            }
        },
        temporaryRoot: URL = FileManager.default.temporaryDirectory
    ) {
        self.capture = capture ?? CaptureController()
        self.makeTranscriber = transcriberFactory
        self.requestPermission = requestPermission
        self.temporaryRoot = temporaryRoot
    }

    public func start(locale: Locale) {
        guard !isActive else { return }
        phase = .starting
        errorMessage = nil
        prefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionID = UUID()
        self.sessionID = sessionID
        let live = makeTranscriber()
        self.live = live
        let directory = temporaryRoot.appending(path: "pepito-instructions-\(UUID())")
        self.directory = directory
        startup = Task {
            do {
                guard await requestPermission() else { throw CaptureError.permissionDenied(.microphone) }
                try Task.checkCancellation()
                try await live.start(locale: locale)
                try Task.checkCancellation()
                updatesTask = Task {
                    for await update in live.updates {
                        let words = update.finalizedSegments.map(\.text) + [update.volatileText]
                        text = Self.join([prefix] + words)
                        if let error = update.errorMessage {
                            errorMessage = error
                            Task { if self.sessionID == sessionID { await self.stop() } }
                        }
                    }
                }
                try await capture.start(
                    sources: [.microphone], in: directory,
                    microphoneEchoCancellation: false, systemAudioBundleID: nil,
                    onMicBuffer: { live.ingest($0) }, onSystemBuffer: nil)
                try Task.checkCancellation()
                phase = .recording
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
                // Ne pas attendre stop ici : il attend la fin de cette tâche de démarrage.
                Task { if self.sessionID == sessionID { await self.stop() } }
            }
        }
    }

    /// Partagé entre bouton Arrêter, fermeture de fenêtre et lancement de l'analyse.
    /// Un arrêt pendant le chargement empêche tout démarrage tardif du micro.
    public func stop() async {
        if let stoppingTask { await stoppingTask.value; return }
        guard isActive else { return }
        phase = .stopping
        startup?.cancel()
        let task = Task {
            await startup?.value
            if capture.isRecording {
                do { try await capture.stop() }
                catch { errorMessage = error.localizedDescription }
            }
            let final = await live?.finish() ?? []
            await updatesTask?.value
            if !final.isEmpty {
                text = Self.join([prefix] + final.map(\.text))
            }
            // Le CAF n'est qu'un support local temporaire, jamais envoyé à un endpoint.
            if let directory, FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { errorMessage = "Dictée arrêtée ; suppression de l'audio temporaire impossible : \(error.localizedDescription)" }
            }
            live = nil
            startup = nil
            updatesTask = nil
            directory = nil
            sessionID = nil
            stoppingTask = nil
            phase = .idle
        }
        stoppingTask = task
        await task.value
    }

    private static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
