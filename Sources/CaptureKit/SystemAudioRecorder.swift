import Foundation
import AVFoundation

/// Contrat de capture de la sortie audio système (audio des autres participants).
/// `onBuffer` (optionnel) reçoit chaque buffer capté, pour alimenter une transcription live.
public protocol SystemAudioRecording: Sendable {
    /// `bundleID` non nil/non vide = ne capturer que la sortie de cette application (repli global si
    /// elle est absente). nil ou vide = toute la sortie système.
    func start(writingTo url: URL, bundleID: String?, onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?) async throws
    func stop() async throws
}
