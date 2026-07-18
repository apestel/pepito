import Testing
import Foundation
@testable import CaptureKit

@Test func moduleIdentity() {
    #expect(CaptureKit.moduleName == "CaptureKit")
}

@Test func audioSourcesAreExhaustive() {
    #expect(Set(AudioSource.allCases) == [.microphone, .system])
}

// MARK: - RecordingSession

@Test func sessionFilesPerSource() {
    let dir = URL(fileURLWithPath: "/tmp/session")
    let session = RecordingSession(directory: dir, sources: [.microphone, .system])
    #expect(session.fileURL(for: .microphone).lastPathComponent == "microphone.caf")
    #expect(session.expectedFiles.count == 2)
    // Ordre déterministe (microphone avant system)
    #expect(session.expectedFiles.first?.lastPathComponent == "microphone.caf")
}

// MARK: - Machine à états

@Test func captureStateMachineTransitions() async throws {
    let engine = MockCaptureEngine()
    #expect(engine.state == .idle)

    try await engine.start(sources: [.microphone])
    #expect(engine.state == .recording)

    try await engine.pause()
    #expect(engine.state == .paused)

    try await engine.stop()
    #expect(engine.state == .stopped)
}

@Test func cannotStartTwice() async throws {
    let engine = MockCaptureEngine()
    try await engine.start(sources: [.microphone])
    await #expect(throws: CaptureError.alreadyRecording) {
        try await engine.start(sources: [.microphone])
    }
}

@Test func cannotPauseWhenIdle() async {
    let engine = MockCaptureEngine()
    await #expect(throws: CaptureError.notRecording) {
        try await engine.pause()
    }
}

@Test func captureErrorMessagesAreLocalized() {
    #expect(CaptureError.alreadyRecording.errorDescription?.isEmpty == false)
    #expect(CaptureError.audioHardware(-10851).errorDescription?.contains("-10851") == true)
}
