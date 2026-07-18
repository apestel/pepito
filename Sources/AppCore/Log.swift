import os

/// Journalisation centralisée. Un `Logger` par sous-système/Kit.
/// Ne jamais logger de PII ni de contenu de transcript par défaut (voir CLAUDE.md §9).
public enum Log {
    public static let subsystem = "com.pepito.app"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
