import Foundation

/// Conventions d'arborescence du Vault (ex. `AAAA/MM/JJ-slug/…`) + slugification.
public enum PathBuilder {
    /// Transforme un titre en slug sûr pour un nom de fichier/dossier.
    public static func slugify(_ input: String) -> String {
        let mapped = input.lowercased().map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        var slug = String(mapped)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "sans-titre" : slug
    }

    /// Dossier d'une réunion : `AAAA/MM/JJ-slug`.
    public static func meetingFolder(
        date: Date,
        title: String,
        calendar: Calendar = .current
    ) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let y = String(format: "%04d", c.year ?? 0)
        let m = String(format: "%02d", c.month ?? 0)
        let d = String(format: "%02d", c.day ?? 0)
        return "\(y)/\(m)/\(d)-\(slugify(title))"
    }

    /// Chemins standard des documents d'une réunion.
    public static func transcriptPath(meetingFolder: String) -> String { "\(meetingFolder)/transcript.md" }
    public static func summaryPath(meetingFolder: String) -> String { "\(meetingFolder)/summary.md" }
    public static func actionPlanPath(meetingFolder: String) -> String { "\(meetingFolder)/action-plan.md" }

    /// Revue de boîte mail du jour : `mails/revue-AAAA-MM-JJ.md` (une par jour, réécrite si on
    /// relance le triage).
    public static func mailReportPath(day: String) -> String { "mails/revue-\(day).md" }

    public static func mailReportPath(date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return mailReportPath(day: String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
    }
}
