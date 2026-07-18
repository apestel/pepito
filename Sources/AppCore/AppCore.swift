import CaptureKit
import TranscriptionKit
import AIKit
import VaultKit
import ActionKit

/// Métadonnées du module et point d'assemblage des Kits.
/// Le coordinateur applicatif (sessions de capture, pipeline agentic) s'étoffera aux Phases 1-5.
public enum AppCore {
    public static let moduleName = "AppCore"

    /// Vérifie que tous les Kits sont liés et exposent leur identité (fumée / smoke check).
    public static func linkedKits() -> [String] {
        [
            CaptureKit.moduleName,
            TranscriptionKit.moduleName,
            AIKit.moduleName,
            VaultKit.moduleName,
            ActionKit.moduleName,
        ]
    }
}
