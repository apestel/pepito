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
        // Le bloc d'entrée du convertisseur est `@Sendable`, alors qu'AVAudioPCMBuffer ne l'est pas
        // et qu'un `var` capturé serait muté hors du fil de l'appelant — deux choses que Swift 6
        // refuse. La boîte porte les deux : elle rend le buffer une fois, puis nil, ce qui signale
        // la fin de l'entrée sans drapeau séparé. (Jumelle de `LivePendingBuffer` dans
        // TranscriptionKit ; 4 lignes, pas de quoi coupler les deux Kits.)
        let pending = PendingBuffer(inBuf)
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            guard let next = pending.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        if let convError { throw convError }
        let n = Int(outBuf.frameLength)
        guard n > 0, let p = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    /// Écrit le micro nettoyé. **Échoue** s'il n'y a rien à écrire : un micro illisible ou vide
    /// remonte ici sous forme de tableau vide (`readMono16k` puis `cancel` le propagent), et écrire
    /// un CAF vide ferait « réussir » l'AEC — le pipeline transcrirait alors du silence et tout le
    /// transcript micro de la réunion serait perdu sans un mot. En échouant, on laisse
    /// `transcribeWithOfflineAEC` retomber sur la transcription normale.
    private static func writeMono16k(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        // Fichier créé en dernier : un échec ne laisse pas un CAF vide derrière lui.
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buf)
    }
}

/// Livre un buffer une seule fois au bloc d'entrée du convertisseur, puis nil (= fin de l'entrée).
/// `@unchecked` assumé : `AVAudioConverter.convert` appelle le bloc de façon synchrone sur le fil
/// appelant, donc il n'y a pas d'accès concurrent malgré la signature `@Sendable`.
private final class PendingBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
}
