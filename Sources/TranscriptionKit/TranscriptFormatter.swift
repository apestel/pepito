import Foundation

/// Met en forme des segments en texte exploitable (contexte IA, écriture Vault).
public enum TranscriptFormatter {
    /// Texte brut, un segment par ligne, préfixé du locuteur si connu.
    public static func plainText(_ segments: [TranscriptSegment]) -> String {
        segments
            .sorted { $0.start < $1.start }
            .map { seg in
                if let speaker = seg.speakerLabel, !speaker.isEmpty {
                    return "\(speaker): \(seg.text)"
                }
                return seg.text
            }
            .joined(separator: "\n")
    }

    /// Fusionne les segments consécutifs d'un même locuteur (lisibilité).
    public static func mergingSameSpeaker(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, last.speakerLabel == seg.speakerLabel {
                last.end = seg.end
                last.text += " " + seg.text
                result[result.count - 1] = last
            } else {
                result.append(seg)
            }
        }
        return result
    }
}
