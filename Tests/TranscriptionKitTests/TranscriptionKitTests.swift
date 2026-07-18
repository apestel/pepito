import Testing
import Foundation
@testable import TranscriptionKit

@Test func moduleIdentity() {
    #expect(TranscriptionKit.moduleName == "TranscriptionKit")
}

@Test func segmentStoresTimingAndSource() {
    let seg = TranscriptSegment(start: 1.0, end: 2.5, text: "bonjour", confidence: 0.9)
    #expect(seg.end > seg.start)
    #expect(seg.text == "bonjour")
    #expect(seg.speakerLabel == nil)
}

// MARK: - Formatting

@Test func plainTextSortsAndPrefixesSpeaker() {
    let segs = [
        TranscriptSegment(start: 2, end: 3, text: "monde", speakerLabel: "Bob"),
        TranscriptSegment(start: 0, end: 1, text: "bonjour", speakerLabel: "Alice"),
    ]
    #expect(TranscriptFormatter.plainText(segs) == "Alice: bonjour\nBob: monde")
}

@Test func mergingConsecutiveSameSpeaker() {
    let segs = [
        TranscriptSegment(start: 0, end: 1, text: "salut", speakerLabel: "Alice"),
        TranscriptSegment(start: 1, end: 2, text: "ça va", speakerLabel: "Alice"),
        TranscriptSegment(start: 2, end: 3, text: "oui", speakerLabel: "Bob"),
    ]
    let merged = TranscriptFormatter.mergingSameSpeaker(segs)
    #expect(merged.count == 2)
    #expect(merged.first?.text == "salut ça va")
    #expect(merged.first?.end == 2)
}

// MARK: - Transcribers

@Test func mockTranscriberReturnsSegments() async throws {
    let expected = [TranscriptSegment(start: 0, end: 1, text: "test")]
    let transcriber = MockTranscriber(segments: expected)
    let result = try await transcriber.transcribeFile(
        at: URL(fileURLWithPath: "/tmp/a.caf"),
        locale: Locale(identifier: "fr-FR")
    )
    #expect(result == expected)
}

@Test func speechAnalyzerRejectsMissingFile() async {
    // L'implémentation réelle échoue proprement sur un fichier absent (ouverture AVAudioFile).
    let transcriber = SpeechAnalyzerTranscriber()
    await #expect(throws: (any Error).self) {
        _ = try await transcriber.transcribeFile(
            at: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).caf"),
            locale: Locale(identifier: "fr-FR")
        )
    }
}
