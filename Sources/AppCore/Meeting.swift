import Foundation

/// Cycle de vie d'une réunion. Sert aussi d'**étape de workflow** pour la reprise : un échec laisse
/// `status` sur l'étape fautive (et renseigne `Meeting.lastError`) au lieu de forcer `.done`.
public enum MeetingStatus: String, Sendable, Codable, CaseIterable {
    case recording
    /// Arrêté, en attente de nom + tags (fenêtre de nommage).
    case awaitingName
    case transcribing
    case processing
    case done

    /// Étapes non terminales : une réunion dans cet état est reprenable.
    public var isResumable: Bool { self != .done && self != .recording }
}

/// Métadonnées d'une réunion. Le contenu (transcript, résumé, plan d'action) vit dans le Vault.
public struct Meeting: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var participants: [String]
    public var status: MeetingStatus
    public var tags: [String]
    /// Dossier du Vault (`AAAA/MM/JJ-slug`).
    public var folderPath: String
    /// Dossier des fichiers audio de la session (pour reprendre une transcription).
    public var sessionDirPath: String?
    /// Transcript finalisé, persisté pour reprendre l'analyse sans re-transcrire.
    public var transcript: String?
    /// Message d'erreur de la dernière étape échouée (nil si aucune).
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        participants: [String] = [],
        status: MeetingStatus = .recording,
        tags: [String] = [],
        folderPath: String = "",
        sessionDirPath: String? = nil,
        transcript: String? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.participants = participants
        self.status = status
        self.tags = tags
        self.folderPath = folderPath
        self.sessionDirPath = sessionDirPath
        self.transcript = transcript
        self.lastError = lastError
    }

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }
}
