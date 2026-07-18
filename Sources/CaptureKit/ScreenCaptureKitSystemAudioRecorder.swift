import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import os

/// Capture de la sortie audio système via **ScreenCaptureKit** (repli quand les Core Audio process
/// taps ne délivrent pas de flux continu — cf. CLAUDE.md §2). SCK diffuse l'audio système en
/// `CMSampleBuffer` de façon fiable et **sans ducker la sortie**, au prix de la permission
/// « Enregistrement de l'écran » (aucune image n'est exploitée : flux vidéo minimal ignoré).
public final class ScreenCaptureKitSystemAudioRecorder: NSObject, SystemAudioRecording, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct Sink { var file: AVAudioFile?; var url: URL? }
    private let sink = OSAllocatedUnfairLock(initialState: Sink())
    nonisolated(unsafe) private var stream: SCStream?
    nonisolated(unsafe) private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "com.pepito.sck.audio")
    private let firstBufferLogged = OSAllocatedUnfairLock(initialState: false)

    private let logger = Logger(subsystem: "com.pepito.app", category: "SystemCapture")
    private let logSink: @Sendable (String) -> Void
    private func step(_ message: String) {
        logger.info("\(message, privacy: .public)")
        logSink(message)
    }

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.logSink = log
    }

    public func start(writingTo url: URL, bundleID: String? = nil, onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) async throws {
        self.onBuffer = onBuffer
        firstBufferLogged.withLock { $0 = false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        sink.withLock { $0 = Sink(file: nil, url: url) }

        // 1. Contenu partageable (déclenche/vérifie la permission Enregistrement de l'écran).
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.audioHardware(kAudioHardwareBadDeviceError)
        }

        // 2. Filtre : sortie d'une app ciblée (capture propre de la visio) ou toute la sortie système.
        //    Si le bundle id est demandé mais l'app absente → repli global (on ne rate jamais l'audio).
        let filter: SCContentFilter
        if let bundleID, !bundleID.isEmpty,
           let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            step("Capture ciblée sur \(app.applicationName) (\(bundleID)).")
        } else {
            if let bundleID, !bundleID.isEmpty {
                step("App ciblée « \(bundleID) » introuvable — repli capture système globale.")
            }
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2                 // vidéo minimale : requise par SCK mais inutilisée
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        step("Capture système (ScreenCaptureKit) démarrée. En attente de buffers…")
    }

    public func stop() async throws {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        onBuffer = nil
        sink.withLock { $0 = Sink() }
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = Self.makePCM(sampleBuffer) else { return }
        if firstBufferLogged.withLock({ done -> Bool in defer { done = true }; return !done }) {
            step("Premier buffer système reçu (\(pcm.frameLength) frames).")
        }
        sink.withLockUnchecked { sink in
            if sink.file == nil, let url = sink.url {
                sink.file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings)
            }
            try? sink.file?.write(from: pcm)
        }
        onBuffer?(pcm)
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        step("Flux système arrêté : \(error.localizedDescription)")
    }

    // MARK: - Privé

    private static func makePCM(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}

/// Applications actuellement lançées, pour le sélecteur de capture ciblée (Réglages).
/// Nécessite la permission « Enregistrement de l'écran » (même appel que la capture).
public enum SystemAudioApps {
    public struct App: Identifiable, Sendable, Hashable {
        public let bundleID: String
        public let name: String
        public var id: String { bundleID }
        public init(bundleID: String, name: String) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    public static func running() async -> [App] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [] }
        var seen = Set<String>()
        return content.applications
            .compactMap { a -> App? in
                guard !a.bundleIdentifier.isEmpty, !a.applicationName.isEmpty,
                      seen.insert(a.bundleIdentifier).inserted else { return nil }
                return App(bundleID: a.bundleIdentifier, name: a.applicationName)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
