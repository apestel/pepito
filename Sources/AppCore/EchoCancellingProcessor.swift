import Foundation
import AVFoundation

/// AEC hors-ligne, avec buffers bornés : conversion sur disque puis filtrage par blocs de 10 s.
/// Les originaux restent intacts ; le résultat n'est publié qu'une fois entièrement écrit.
enum EchoCancellingProcessor {
    static func process(micURL: URL, referenceURL: URL, outputURL: URL) throws {
        let fm = FileManager.default
        let work = outputURL.deletingLastPathComponent().appendingPathComponent(".aec-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let micURL16 = work.appendingPathComponent("mic.caf")
        let refURL16 = work.appendingPathComponent("reference.caf")
        try convert(micURL, to: micURL16)
        try convert(referenceURL, to: refURL16)
        let mic = try AVAudioFile(forReading: micURL16)
        let reference = try AVAudioFile(forReading: refURL16)
        guard mic.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let result = work.appendingPathComponent("result.caf")
        try filter(mic: mic, reference: reference, to: result)
        // rename POSIX atomique sur le même volume, y compris si un ancien résultat existe.
        guard rename(result.path, outputURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func filter(mic: AVAudioFile, reference: AVAudioFile, to url: URL) throws {
        let aec = EchoCanceller()
        var state = EchoCanceller.State()
        let output = try AVAudioFile(forWriting: url, settings: mic.processingFormat.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: mic.processingFormat,
                                      frameCapacity: AVAudioFrameCount(aec.blockLength))!
        while mic.framePosition < mic.length {
            let offset = Int(mic.framePosition)
            let samples = try read(mic, count: aec.blockLength)
            guard !samples.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let range = aec.referenceRange(offset: offset, count: samples.count, maxLag: 4000, state: state)
            reference.framePosition = min(AVAudioFramePosition(range.lowerBound), reference.length)
            let ref = try read(reference, count: range.count)
            let cleaned = reference.length == 0 ? samples : aec.cancelBlock(
                mic: samples, reference: ref, referenceOffset: offset - range.lowerBound,
                maxLag: 4000, state: &state)
            buffer.frameLength = AVAudioFrameCount(cleaned.count)
            cleaned.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: cleaned.count) }
            try output.write(from: buffer)
        }
    }

    private static func read(_ file: AVAudioFile, count: Int) throws -> [Float] {
        let n = min(count, Int(file.length - file.framePosition))
        guard n > 0 else { return [] }
        var samples: [Float] = []
        samples.reserveCapacity(n)
        // AVAudioFile peut livrer moins que la capacité demandée, même avant EOF.
        // Compléter le bloc conserve les frontières d'adaptation NLMS et toute la référence.
        while samples.count < n {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                               frameCapacity: AVAudioFrameCount(n - samples.count)) else {
                throw CocoaError(.fileReadUnknown)
            }
            try file.read(into: buffer, frameCount: AVAudioFrameCount(n - samples.count))
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    private static func convert(_ source: URL, to destination: URL) throws {
        let input = try ConversionInput(source)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.file.processingFormat, to: format),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        while true {
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { count, status in
                input.read(count: count, status: status)
            }
            if let error = input.error { throw error }
            if let error { throw error }
            if buffer.frameLength > 0 { try output.write(from: buffer) }
            if status == .endOfStream { return }
            guard status != .error, buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
    }
}

/// Le callback AVAudioConverter est synchrone ; cette boîte reste sur le fil du traitement.
private final class ConversionInput: @unchecked Sendable {
    let file: AVAudioFile
    var error: (any Error)?
    init(_ url: URL) throws { file = try AVAudioFile(forReading: url) }
    func read(count: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard file.framePosition < file.length else { status.pointee = .endOfStream; return nil }
        do {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: min(count, 16384)) else {
                throw CocoaError(.fileReadUnknown)
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            status.pointee = .haveData
            return buffer
        } catch {
            self.error = error
            status.pointee = .endOfStream
            return nil
        }
    }
}
