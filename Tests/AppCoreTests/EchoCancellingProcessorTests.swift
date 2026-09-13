import Testing
import Foundation
import AVFoundation
@testable import AppCore

/// Écrit un fichier CAF Float32 de `seconds` secondes à `rate` Hz / `channels` canaux, rempli
/// d'une sinusoïde (une valeur non nulle suffit : on vérifie la conversion, pas l'acoustique).
private func writeTone(_ url: URL, rate: Double, channels: AVAudioChannelCount, seconds: Double) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                               channels: channels, interleaved: false)!
    let frames = AVAudioFrameCount(rate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buf.frameLength = frames
    for c in 0..<Int(channels) {
        for i in 0..<Int(frames) {
            buf.floatChannelData![c][i] = sin(2 * .pi * 440 * Float(i) / Float(rate)) * 0.5
        }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buf)
}

// Le bloc d'entrée d'AVAudioConverter est `@Sendable` : le buffer y est livré par une boîte qui
// ne le rend qu'une fois, puis nil pour signaler la fin. Si cette mécanique casse, la conversion
// rend un fichier vide (jamais livré) ou boucle (livré sans fin) — d'où le contrôle de durée.
@Test func echoProcessorResamplesToMono16k() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-aec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let mic = dir.appending(path: "micro.caf")
    let reference = dir.appending(path: "system.caf")
    let output = dir.appending(path: "clean.caf")
    try writeTone(mic, rate: 48000, channels: 2, seconds: 1)      // stéréo 48 kHz → doit être ramené
    try writeTone(reference, rate: 16000, channels: 1, seconds: 1)

    try EchoCancellingProcessor.process(micURL: mic, referenceURL: reference, outputURL: output)

    let result = try AVAudioFile(forReading: output)
    #expect(result.processingFormat.sampleRate == 16000)
    #expect(result.processingFormat.channelCount == 1)
    // ~1 s à 16 kHz. Large tolérance : le rééchantillonnage a de la latence, mais ni 0 ni 10×.
    #expect(result.length > 12000 && result.length < 20000)
}

/// Écrit `samples` en mono 16 kHz (format déjà cible : aucun rééchantillonnage en jeu).
private func writeMono16k(_ url: URL, _ samples: [Float]) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                               channels: 1, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buf)
}

private func energy(_ url: URL) throws -> Float {
    let file = try AVAudioFile(forReading: url)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                               frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    let p = buf.floatChannelData![0]
    return (0..<Int(buf.frameLength)).reduce(Float(0)) { $0 + p[$1] * p[$1] }
}

// L'annulation elle-même est testée sur les tableaux (`echoCancellerReducesReferenceEcho`) ; ici on
// vérifie le **câblage fichier** autour : lire, annuler, écrire. Un bug de mono-isation, de canal ou
// d'ordre des arguments passerait les tests unitaires de l'algorithme et ressortirait ici.
@Test func echoProcessorRemovesEchoThroughFiles() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-aec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Référence large bande déterministe ; micro = cette référence retardée et atténuée (écho pur,
    // pas de voix proche) → après AEC il ne doit quasiment plus rien rester.
    let n = 32000, delay = 60
    var state: UInt32 = 12345
    var reference = [Float](repeating: 0, count: n)
    for i in 0..<n {
        state = state &* 1664525 &+ 1013904223
        reference[i] = Float(state) / Float(UInt32.max) * 2 - 1
    }
    let mic = (0..<n).map { i in i >= delay ? 0.3 * reference[i - delay] : 0 }

    let micURL = dir.appending(path: "micro.caf")
    let refURL = dir.appending(path: "system.caf")
    let outURL = dir.appending(path: "clean.caf")
    try writeMono16k(micURL, mic)
    try writeMono16k(refURL, reference)

    try EchoCancellingProcessor.process(micURL: micURL, referenceURL: refURL, outputURL: outURL)

    #expect(try energy(outURL) < 0.2 * energy(micURL))   // >7 dB, même seuil que le test algo
}

// Un micro illisible ou vide doit faire ÉCHOUER l'AEC, pas produire un CAF vide : le pipeline
// transcrirait alors du silence et perdrait tout le transcript micro sans un mot d'erreur.
@Test func echoProcessorFailsRatherThanWritingSilence() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-aec-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                               channels: 1, interleaved: false)!
    let micURL = dir.appending(path: "micro.caf")
    _ = try AVAudioFile(forWriting: micURL, settings: format.settings)   // valide mais 0 frame
    let refURL = dir.appending(path: "system.caf")
    try writeMono16k(refURL, [Float](repeating: 0.1, count: 16000))
    let outURL = dir.appending(path: "clean.caf")

    #expect(throws: (any Error).self) {
        try EchoCancellingProcessor.process(micURL: micURL, referenceURL: refURL, outputURL: outURL)
    }
    // Et surtout : pas de fichier vide laissé derrière, que le pipeline prendrait pour un succès.
    #expect(FileManager.default.fileExists(atPath: outURL.path) == false)
}

@Test(arguments: [-180, 180])
func echoStreamingMatchesWholeFileAcrossBlocks(delay: Int) throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aec-stream-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let n = 330_000
    var seed: UInt32 = 75
    let reference: [Float] = (0..<(n - 5000)).map { _ in
        seed = seed &* 1664525 &+ 1013904223
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }
    let mic: [Float] = (0..<n).map { i in
        let source = i - delay - (i / 160_000) * 40
        return reference.indices.contains(source) ? reference[source] * 0.3 : 0.02
    }
    let expected = EchoCanceller().cancel(mic: mic, reference: reference, maxLag: 4000)
    let aec = EchoCanceller()
    var state = EchoCanceller.State()
    var blocks: [Float] = []
    for offset in stride(from: 0, to: n, by: aec.blockLength) {
        let count = min(aec.blockLength, n - offset)
        let range = aec.referenceRange(offset: offset, count: count, maxLag: 4000, state: state)
        let ref = Array(reference[min(range.lowerBound, reference.count)..<min(range.upperBound, reference.count)])
        blocks += aec.cancelBlock(mic: Array(mic[offset..<offset+count]), reference: ref,
                                  referenceOffset: offset - range.lowerBound, maxLag: 4000, state: &state)
    }
    #expect(blocks == expected)

    let micURL = dir.appendingPathComponent("mic.caf"), refURL = dir.appendingPathComponent("ref.caf")
    let outURL = dir.appendingPathComponent("out.caf")
    try writeMono16k(micURL, mic)
    try writeMono16k(refURL, reference)
    try EchoCancellingProcessor.process(micURL: micURL, referenceURL: refURL, outputURL: outURL)
    let file = try AVAudioFile(forReading: outURL)
    #expect(file.length == AVAudioFramePosition(n))
    var actual: [Float] = []
    while file.framePosition < file.length {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        try file.read(into: buffer)
        try #require(buffer.frameLength > 0)
        actual.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    #expect(actual.count == n)
    #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.00001 })
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 3)
}
