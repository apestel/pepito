import Foundation
import AVFoundation

/// Abstraction de capture, injectable pour tester l'orchestration sans matériel audio.
@MainActor
public protocol AudioCapturing: AnyObject {
    var isRecording: Bool { get }
    var startedSources: Set<AudioSource> { get }
    @discardableResult
    func start(
        sources: Set<AudioSource>,
        in directory: URL,
        microphoneEchoCancellation: Bool,
        systemAudioBundleID: String?,
        onMicBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
        onSystemBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) async throws -> RecordingSession
    func stop() async throws
}

extension CaptureController: AudioCapturing {}
