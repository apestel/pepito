/// Capture audio double-source (micro + sortie système). Implémentation en Phase 1 (PLAN.md).
public enum CaptureKit {
    public static let moduleName = "CaptureKit"
}

/// Source audio d'un flux capturé. La distinction sert à la diarisation grossière (moi vs eux).
public enum AudioSource: String, Sendable, CaseIterable {
    case microphone
    case system
}

/// État d'une session de capture.
public enum CaptureState: Sendable, Equatable {
    case idle
    case recording
    case paused
    case stopped
}

/// Contrat de capture, mockable pour les tests (aucun matériel requis).
public protocol CaptureEngine: Sendable {
    var state: CaptureState { get }
    func start(sources: Set<AudioSource>) async throws
    func pause() async throws
    func stop() async throws
}
