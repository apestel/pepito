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

/// Occurrences d'une même réunion récurrente, plus récente en tête. Une réunion isolée forme une
/// série d'un seul élément (affichée comme une simple ligne).
public struct MeetingSeries: Sendable, Identifiable, Equatable {
    public let key: String
    public let meetings: [Meeting]

    public init(key: String, meetings: [Meeting]) {
        self.key = key
        self.meetings = meetings
    }

    public var id: String { key }
    public var isRecurring: Bool { meetings.count > 1 }
    /// Titre de l'occurrence la plus récente : le libellé peut varier à la marge d'une fois à
    /// l'autre, on montre le dernier en date.
    public var title: String { meetings.first?.title ?? key }
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
    /// Projet de la réunion, choisi dès le démarrage (rapproché du titre de l'événement calendrier)
    /// et hérité par ses actions. Cible aussi le pré-brief, qui ne peut pas attendre les tags de fin.
    public var projectID: UUID?
    /// Dossier du Vault (`AAAA/MM/JJ-slug-UUID` pour les nouvelles réunions, ancien chemin conservé).
    public var folderPath: String
    /// Dossier des fichiers audio de la session (pour reprendre une transcription).
    public var sessionDirPath: String?
    /// Transcript finalisé, persisté pour reprendre l'analyse sans re-transcrire.
    public var transcript: String?
    /// Notes prises par l'utilisateur pendant la réunion (enrichies par l'IA, Phase C).
    public var userNotes: String
    /// Consignes de synthèse propres à cette réunion ; nil pour les anciennes réunions.
    public var summaryInstructions: String?
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
        projectID: UUID? = nil,
        folderPath: String = "",
        sessionDirPath: String? = nil,
        transcript: String? = nil,
        userNotes: String = "",
        summaryInstructions: String? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.participants = participants
        self.status = status
        self.tags = tags
        self.projectID = projectID
        self.folderPath = folderPath
        self.sessionDirPath = sessionDirPath
        self.transcript = transcript
        self.userNotes = userNotes
        self.summaryInstructions = summaryInstructions
        self.lastError = lastError
    }

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// Clé de série : les occurrences d'une réunion récurrente portent le même titre de calendrier.
    /// « Weekly Produit #12 », « weekly produit — 28/07 » et « Weekly Produit » tombent ensemble.
    ///
    /// ponytail: dérivée du titre, donc une réunion renommée quitte son groupe. Si ça gêne :
    /// colonne `series_key` alimentée par l'identifiant de série d'`EKEvent`.
    /// Un titre auto (« Réunion du 21 août 2026 à 14:32 ») ne forme jamais de série : sans lui,
    /// deux réunions impromptues du même mois tomberaient dans le même groupe (les nombres sont
    /// filtrés, le nom du mois non).
    public var seriesKey: String {
        title.hasPrefix(Self.autoTitlePrefix) ? id.uuidString : Self.seriesKey(title)
    }

    /// Préfixe du titre donné à une réunion démarrée hors événement calendrier.
    public static let autoTitlePrefix = "Réunion du "

    public static func seriesKey(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let words = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            // Chiffres, numéros d'occurrence et dates varient d'une occurrence à l'autre.
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
        return words.joined(separator: " ")
    }
}
