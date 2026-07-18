import Foundation
import os

/// Machine à états de capture, sans matériel — sert aux tests et aux previews.
public final class MockCaptureEngine: CaptureEngine {
    private let box = OSAllocatedUnfairLock(initialState: CaptureState.idle)

    public init() {}

    public var state: CaptureState { box.withLock { $0 } }

    public func start(sources: Set<AudioSource>) async throws {
        try box.withLock { current in
            guard current == .idle || current == .stopped else {
                throw CaptureError.alreadyRecording
            }
            current = .recording
        }
    }

    public func pause() async throws {
        try box.withLock { current in
            guard current == .recording else { throw CaptureError.notRecording }
            current = .paused
        }
    }

    public func stop() async throws {
        try box.withLock { current in
            guard current == .recording || current == .paused else {
                throw CaptureError.notRecording
            }
            current = .stopped
        }
    }
}
