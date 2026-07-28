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
