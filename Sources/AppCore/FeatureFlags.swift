/// Drapeaux de configuration centralisés (Phase 0, PLAN.md).
/// Permettent d'arbitrer on-device vs distant et les sources de capture sans toucher au code.
public struct FeatureFlags: Sendable, Equatable, Codable {
    /// Utiliser un modèle génératif on-device (Foundation Models) plutôt que l'endpoint distant.
    public var useOnDeviceAI: Bool
    /// Capturer le micro (uniquement s'il est réellement actif).
    public var captureMicrophone: Bool
    /// Capturer la sortie audio système (audio des autres participants).
    public var captureSystemAudio: Bool
    /// Afficher une prévisualisation « proposé par l'IA » avant écriture dans le Vault.
    public var reviewAIProposalsBeforeWrite: Bool

    public init(
        useOnDeviceAI: Bool = false,
        captureMicrophone: Bool = true,
        captureSystemAudio: Bool = true,
        reviewAIProposalsBeforeWrite: Bool = true
    ) {
        self.useOnDeviceAI = useOnDeviceAI
        self.captureMicrophone = captureMicrophone
        self.captureSystemAudio = captureSystemAudio
        self.reviewAIProposalsBeforeWrite = reviewAIProposalsBeforeWrite
    }

    public static let `default` = FeatureFlags()
}
