import Foundation
import TranscriptionKit

/// Filtre le « bleed » micro : quand on écoute sur haut-parleurs, le micro (« Moi ») recapte la voix
/// des interlocuteurs sortant des HP, produisant un doublon du transcript système. Comme le flux
/// système est la source *propre* de cette voix, on retire les segments micro dont le texte recoupe
/// un segment système au même instant. Purement textuel : pas de DSP, pas de ducking, pas de casque.
enum BleedFilter {
    // ponytail: seuils heuristiques (Jaccard 0.6, ±1,5 s) — knobs à ajuster si ça sur/sous-filtre.
    static let similarityThreshold = 0.6
    static let timeTolerance: TimeInterval = 1.5

    /// Renvoie les segments micro **débarrassés** des doublons présents dans le flux système.
    static func micWithoutBleed(mic: [TranscriptSegment], system: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !system.isEmpty else { return mic }
        return mic.filter { m in
            !system.contains { s in overlaps(m, s) && similar(m.text, s.text) }
        }
    }

    private static func overlaps(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Bool {
        a.start <= b.end + timeTolerance && b.start <= a.end + timeTolerance
    }

    /// Similarité de Jaccard sur les mots normalisés (minuscules, ponctuation retirée).
    static func similar(_ a: String, _ b: String) -> Bool {
        let ta = Set(tokens(a)), tb = Set(tokens(b))
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return Double(inter) / Double(union) >= similarityThreshold
    }

    private static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
