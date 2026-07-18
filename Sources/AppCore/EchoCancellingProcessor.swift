import Foundation
import AVFoundation

/// Applique l'AEC hors-ligne à un couple de fichiers : lit `micro.caf` (voix + bleed) et
/// `system.caf` (référence propre), les ramène en mono 16 kHz, annule l'écho, écrit le micro nettoyé.
/// Statique et pur fichiers → appelable hors du MainActor (traitement lourd en arrière-plan).
enum EchoCancellingProcessor {
    private static let sampleRate = 16000.0

    static func process(micURL: URL, referenceURL: URL, outputURL: URL) throws {
        let mic = try readMono16k(micURL)
        let reference = try readMono16k(referenceURL)
        let aec = EchoCanceller()
        let maxLag = Int(sampleRate / 4)   // recherche de délai jusqu'à ±250 ms
        let cleaned = aec.cancel(mic: mic, reference: reference, maxLag: maxLag)
        try writeMono16k(cleaned, to: outputURL)
    }

    /// Lit un fichier audio et le convertit en Float32 mono 16 kHz.
    private static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: target) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let srcFrames = AVAudioFrameCount(file.length)
        guard srcFrames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: srcFrames) else { return [] }
        try file.read(into: inBuf)

        let capacity = AVAudioFrameCount(Double(srcFrames) * sampleRate / srcFormat.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var supplied = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }
        if let convError { throw convError }
        let n = Int(outBuf.frameLength)
        guard n > 0, let p = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    private static func writeMono16k(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
    }
}
