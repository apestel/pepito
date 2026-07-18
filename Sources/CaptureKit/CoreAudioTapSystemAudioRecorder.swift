import Foundation
import CoreAudio
import AVFoundation
import os

/// Capture de la sortie audio système via **Core Audio process taps** (macOS 14.4+).
/// Contrairement à ScreenCaptureKit, cela ne requiert **pas** la permission d'enregistrement
/// d'écran — uniquement l'accès à l'audio système (`NSAudioCaptureUsageDescription`), sans
/// rappels périodiques ni indicateur de capture d'écran. Principe : tap sur les process ciblés
/// (ou global), agrégé dans un périphérique privé dont la sortie par défaut fournit **l'horloge**,
/// puis lecture des buffers via un IOProc.
///
/// Compile contre le SDK ; l'exécution nécessite l'autorisation d'accès à l'audio système (TCC).
public final class CoreAudioTapSystemAudioRecorder: SystemAudioRecording, @unchecked Sendable {
    /// Destination d'écriture, protégée par un verrou utilisable depuis le thread audio et l'async.
    private struct Sink { var file: AVAudioFile?; var format: AVAudioFormat? }
    private let sink = OSAllocatedUnfairLock(uncheckedState: Sink())

    nonisolated(unsafe) private var tapID: AudioObjectID = 0
    nonisolated(unsafe) private var aggregateID: AudioObjectID = 0
    nonisolated(unsafe) private var ioProcID: AudioDeviceIOProcID?
    nonisolated(unsafe) private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let firstBufferLogged = OSAllocatedUnfairLock(initialState: false)

    private let logger = Logger(subsystem: "com.pepito.app", category: "SystemCapture")
    private let logSink: @Sendable (String) -> Void
    private func step(_ message: String) {
        logger.info("\(message, privacy: .public)")
        logSink(message)
    }

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.logSink = log
    }

    public func start(writingTo url: URL, bundleID: String? = nil, onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) async throws {
        self.onBuffer = onBuffer
        firstBufferLogged.withLock { $0 = false }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 1. Tap stéréo : mixdown des process de l'app ciblée (Teams = app + helpers, d'où le match
        //    par préfixe de bundle id), sinon tap global. App demandée mais sans process audio →
        //    repli global, même contrat que le chemin ScreenCaptureKit (on ne rate jamais l'audio).
        // ponytail: process résolus au démarrage seulement ; écouter
        // kAudioHardwarePropertyProcessObjectList si un helper apparu en cours de réunion manquait.
        let description: CATapDescription
        if let bundleID, !bundleID.isEmpty {
            let processes = processObjects(withBundlePrefix: bundleID)
            if processes.isEmpty {
                step("App ciblée « \(bundleID) » sans process audio — repli tap global.")
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            } else {
                step("Tap ciblé sur \(processes.count) process de « \(bundleID) ».")
                description = CATapDescription(stereoMixdownOfProcesses: processes)
            }
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap: AudioObjectID = 0
        try check(AudioHardwareCreateProcessTap(description, &tap))
        tapID = tap
        step("Tap système créé (id=\(tap)).")

        // L'UID du tap créé est celui de sa description.
        let tapUID = description.uuid.uuidString

        // 2. Format du tap → format audio + fichier de sortie.
        var asbd = try tapStreamFormat(tap)
        guard let audioFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.audioHardware(kAudioHardwareUnsupportedOperationError)
        }
        step("Format tap : \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) canal/aux.")
        let audioFile = try AVAudioFile(forWriting: url, settings: audioFormat.settings)
        sink.withLockUnchecked { $0.file = audioFile; $0.format = audioFormat }

        // 3. Périphérique agrégé privé : la **sortie par défaut en sous-périphérique maître** fournit
        // l'horloge qui cadence l'IOProc — sans elle l'agrégat ne contient que le tap et ne délivre
        // qu'un buffer (panne observée ici). Le ducking constaté lors d'un essai antérieur venait de
        // la VPIO micro (AEC `osVoiceProcessing`), pas de ce sous-périphérique ; l'IOProc ne touche
        // pas aux buffers de sortie (silence).
        let outputUID = try defaultOutputDeviceUID()
        let aggregateUID = "com.pepito.aggregate.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pépito System Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID,
                ],
            ],
        ]
        var aggregate: AudioObjectID = 0
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate))
        aggregateID = aggregate

        // 4. IOProc : reçoit les buffers du tap et les écrit dans le fichier.
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) {
            [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        try check(status)
        guard let procID else {
            throw CaptureError.audioHardware(kAudioHardwareBadDeviceError)
        }
        ioProcID = procID
        try check(AudioDeviceStart(aggregate, procID))
        step("Capture système démarrée (agrégat=\(aggregate)). En attente de buffers…")
    }

    public func stop() async throws {
        if aggregateID != 0, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = 0
        tapID = 0
        onBuffer = nil
        sink.withLockUnchecked { $0.file = nil; $0.format = nil }
    }

    // MARK: - Privé

    /// Écrit les buffers reçus. Appelé sur un thread audio temps-réel : l'écriture disque directe
    /// reste acceptable pour une v1 (à déplacer sur une file dédiée si des glitches apparaissent).
    private func handle(_ bufferList: UnsafePointer<AudioBufferList>) {
        sink.withLockUnchecked { sink in
            guard let format = sink.format, let file = sink.file,
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList) else { return }
            // Diagnostic : confirme (une fois) que l'IOProc délivre bien de l'audio système.
            if firstBufferLogged.withLock({ done -> Bool in defer { done = true }; return !done }) {
                step("Premier buffer système reçu (\(pcm.frameLength) frames).")
            }
            try? file.write(from: pcm)
            self.onBuffer?(pcm)
        }
    }

    /// UID du périphérique de sortie par défaut — sous-périphérique d'horloge de l'agrégat.
    private func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID))
        return try stringProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Objets process audio dont le bundle id commence par `prefix` (l'app choisie et ses helpers).
    private func processObjects(withBundlePrefix prefix: String) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter { object in
            (try? stringProperty(of: object, selector: kAudioProcessPropertyBundleID))?.hasPrefix(prefix) == true
        }
    }

    private func stringProperty(of object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value))
        return value as String
    }

    private func tapStreamFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd))
        return asbd
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.audioHardware(status) }
    }
}
