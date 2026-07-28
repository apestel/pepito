import Foundation

/// Stratégie d'annulation d'écho micro (bleed des haut-parleurs recapté par le micro).
public enum EchoCancellationMode: String, Codable, CaseIterable, Sendable {
    /// AEC d'Apple (voice-processing) en temps réel — optimisée, mais peut ducker la sortie.
    case osVoiceProcessing
    /// NLMS hors-ligne sur les fichiers après la réunion — ne touche jamais au volume de sortie.
    case offlineReference
    /// Aucune annulation (repli casque + dé-duplication texte).
    case off

    public var label: String {
        switch self {
        case .osVoiceProcessing: "AEC système (temps réel — ⚠️ bloque le micro des autres apps)"
        case .offlineReference: "AEC hors-ligne (sans ducking)"
        case .off: "Désactivée"
        }
    }
}

/// Réglages persistés (hors token, qui vit en Keychain). Pilotés par l'interface d'admin (Phase 6).
public struct Settings: Sendable, Codable, Equatable {
    public var aiBaseURL: String
    public var aiModel: String
    /// Chemin racine du Vault documentaire.
    public var vaultPath: String
    /// Prompt agentic déclenché en fin de transcript.
    public var agenticPrompt: String
    public var transcriptionLocaleIdentifier: String
    public var flags: FeatureFlags
    /// Stratégie d'annulation d'écho micro.
    public var echoCancellation: EchoCancellationMode
    /// Bundle id de l'application dont capturer la sortie audio (piste « Interlocuteurs »).
    /// Vide = toute la sortie système (comportement par défaut). App absente à l'enregistrement = repli global.
    public var systemCaptureBundleID: String
    /// Prompt de triage de la boîte mail (voir `PromptTemplate.defaultMailPrompt`).
    public var mailPrompt: String
    /// Garde-fou : nombre maximum de messages extraits par triage.
    public var mailLimit: Int

    public init(
        aiBaseURL: String = "https://api.openai.com/v1",
        aiModel: String = "gpt-4o",
        vaultPath: String = "",
        agenticPrompt: String = PromptTemplate.defaultAgenticPrompt,
        transcriptionLocaleIdentifier: String = "fr-FR",
        flags: FeatureFlags = .default,
        echoCancellation: EchoCancellationMode = .offlineReference,
        systemCaptureBundleID: String = "",
        mailPrompt: String = PromptTemplate.defaultMailPrompt,
        mailLimit: Int = 300
    ) {
        self.aiBaseURL = aiBaseURL
        self.aiModel = aiModel
        self.vaultPath = vaultPath
        self.agenticPrompt = agenticPrompt
        self.transcriptionLocaleIdentifier = transcriptionLocaleIdentifier
        self.flags = flags
        self.echoCancellation = echoCancellation
        self.systemCaptureBundleID = systemCaptureBundleID
        self.mailPrompt = mailPrompt
        self.mailLimit = mailLimit
    }

    /// Décodage tolérant : un champ absent (ancien fichier) prend sa valeur par défaut, plutôt que
    /// de faire échouer tout le chargement et réinitialiser les réglages.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        aiBaseURL = try c.decodeIfPresent(String.self, forKey: .aiBaseURL) ?? d.aiBaseURL
        aiModel = try c.decodeIfPresent(String.self, forKey: .aiModel) ?? d.aiModel
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath) ?? d.vaultPath
        agenticPrompt = try c.decodeIfPresent(String.self, forKey: .agenticPrompt) ?? d.agenticPrompt
        transcriptionLocaleIdentifier = try c.decodeIfPresent(String.self, forKey: .transcriptionLocaleIdentifier) ?? d.transcriptionLocaleIdentifier
        flags = try c.decodeIfPresent(FeatureFlags.self, forKey: .flags) ?? d.flags
        echoCancellation = try c.decodeIfPresent(EchoCancellationMode.self, forKey: .echoCancellation) ?? d.echoCancellation
        systemCaptureBundleID = try c.decodeIfPresent(String.self, forKey: .systemCaptureBundleID) ?? d.systemCaptureBundleID
        mailPrompt = try c.decodeIfPresent(String.self, forKey: .mailPrompt) ?? d.mailPrompt
        mailLimit = try c.decodeIfPresent(Int.self, forKey: .mailLimit) ?? d.mailLimit
    }

    public static let `default` = Settings()

    /// Indique si la configuration minimale est prête à traiter des réunions.
    public var isConfigured: Bool {
        !vaultPath.isEmpty && URL(string: aiBaseURL) != nil && !aiModel.isEmpty
    }
}
