import Testing
import Foundation
import AVFoundation
import CaptureKit
@testable import AppCore

@Test func linkedKitsAreAllPresent() {
    let kits = AppCore.linkedKits()
    #expect(kits.count == 5)
    #expect(Set(kits) == ["CaptureKit", "TranscriptionKit", "AIKit", "VaultKit", "ActionKit"])
}

@Test func defaultFeatureFlags() {
    let flags = FeatureFlags.default
    #expect(flags.captureMicrophone)
    #expect(flags.captureSystemAudio)
    #expect(flags.useOnDeviceAI == false)
    #expect(flags.reviewAIProposalsBeforeWrite)
}

// MARK: - Prompt template

@Test func promptRenderingInterpolates() {
    let rendered = PromptTemplate.render(
        "Date: {{date}} / Participants: {{participants}} / Arbre: {{vault_tree}}",
        context: PromptContext(transcript: "T", date: "2026-07-15", participants: "Alice, Bob", vaultTree: "a.md")
    )
    #expect(rendered == "Date: 2026-07-15 / Participants: Alice, Bob / Arbre: a.md")
}

// MARK: - Settings persistence

@Test func settingsRoundTripOnDisk() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "pepito-settings-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let store = SettingsStore(fileURL: tmp)
    #expect(store.load() == .default) // absent → défaut

    var settings = Settings.default
    settings.vaultPath = "/Users/me/Vault"
    settings.aiModel = "gpt-4o-mini"
    try store.save(settings)

    #expect(store.load() == settings)
    #expect(settings.isConfigured)
}

// MARK: - Token store

@Test func inMemoryTokenStore() throws {
    let store = InMemoryTokenStore()
    #expect(try store.token(for: "default") == nil)
    try store.setToken("sk-secret", for: "default")
    #expect(try store.token(for: "default") == "sk-secret")
    try store.setToken(nil, for: "default")
    #expect(try store.token(for: "default") == nil)
}

// MARK: - Analyse spectrale (visualisation live FFT)

@Test func spectrumMeterPeaksAtToneFrequency() {
    let meter = SpectrumMeter()
    let sr = 16000.0, freq = 2000.0
    let n = SpectrumMeter.fftSize
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    let p = buf.floatChannelData![0]
    for i in 0..<n { p[i] = Float(sin(2 * .pi * freq * Double(i) / sr)) }

    meter.push(buf, source: .microphone)
    let spec = meter.sample().mic

    // La bande dominante doit correspondre à 2 kHz ; les autres sources restent muettes.
    let peak = spec.enumerated().max { $0.element < $1.element }!.offset
    let expected = Int(freq * Double(n) / sr) * SpectrumMeter.bands / (n / 2)
    #expect(abs(peak - expected) <= 1)
    #expect(spec[peak] > 0.3)
    #expect(meter.sample().system.allSatisfy { $0 == 0 })
}

// MARK: - Filtre du bleed micro

@Test func bleedFilterRemovesMicDuplicatesOfSystem() {
    // Micro : ma phrase (unique) + un doublon de la sortie système (bleed HP).
    let mic = [
        TranscriptSegment(start: 0, end: 2, text: "Je suis d'accord avec toi"),
        TranscriptSegment(start: 3, end: 5, text: "Bonjour comment ça va"),   // bleed
    ]
    let system = [
        TranscriptSegment(start: 3, end: 5, text: "bonjour, comment ça va ?"), // source propre
    ]
    let clean = BleedFilter.micWithoutBleed(mic: mic, system: system)
    #expect(clean.map(\.text) == ["Je suis d'accord avec toi"])

    // Rien de commun avec le système → aucun retrait.
    let unrelated = [TranscriptSegment(start: 3, end: 5, text: "sujet totalement différent")]
    #expect(BleedFilter.micWithoutBleed(mic: mic, system: unrelated).count == 2)

    // Même texte mais hors de la fenêtre temporelle → conservé (pas un doublon simultané).
    let late = [TranscriptSegment(start: 30, end: 32, text: "bonjour comment ça va")]
    #expect(BleedFilter.micWithoutBleed(mic: mic, system: late).count == 2)
}

// MARK: - AEC hors-ligne (NLMS)

@Test func echoCancellerReducesReferenceEcho() {
    let n = 32000, half = 16000, delay = 60
    // Référence large bande (pseudo-aléatoire déterministe) = audio système.
    var state: UInt32 = 12345
    var x = [Float](repeating: 0, count: n)
    for i in 0..<n {
        state = state &* 1664525 &+ 1013904223
        x[i] = Float(state) / Float(UInt32.max) * 2 - 1
    }
    // 1ʳᵉ moitié : écho seul (le filtre converge). 2ᵉ moitié : double-talk — ma voix (ton) s'ajoute ;
    // l'adaptation doit se figer (Geigel), l'écho rester annulé et ma voix survivre.
    var mic = [Float](repeating: 0, count: n)
    var nearEnd = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let s = i >= half ? 0.3 * Float(sin(2 * .pi * 200 * Double(i) / 16000)) : 0
        nearEnd[i] = s
        let echo = i >= delay ? 0.3 * x[i - delay] : 0
        mic[i] = s + echo
    }

    let out = EchoCanceller().cancel(mic: mic, reference: x, maxLag: 250)

    // Sur la moitié double-talk : ce qui dépasse de ma voix (résidu d'écho + distorsion NLMS) doit
    // être bien plus faible que l'écho brut → écho annulé ET voix intacte.
    var residual: Float = 0, rawEcho: Float = 0
    for i in half..<n {
        residual += (out[i] - nearEnd[i]) * (out[i] - nearEnd[i])   // ce qui reste au-delà de ma voix
        rawEcho += (mic[i] - nearEnd[i]) * (mic[i] - nearEnd[i])    // l'écho d'origine
    }
    #expect(residual < 0.2 * rawEcho)          // >7 dB de réduction d'écho
    #expect(EchoCanceller.estimateDelay(mic: mic, reference: x, maxLag: 250) == delay)
}

@Test func echoCancellerTracksClockDrift() {
    // Dérive d'horloge simulée : l'écho arrive 1 échantillon plus TÔT tous les 4000 (dérive cumulée
    // de 96 échantillons) — un alignement unique à t=0 finit non-causal et ne peut plus annuler.
    // Filtre et blocs raccourcis pour un test rapide (mêmes proportions qu'en production).
    let n = 384_000, drift = 4000
    var state: UInt32 = 98765
    var x = [Float](repeating: 0, count: n)
    for i in 0..<n {
        state = state &* 1664525 &+ 1013904223
        x[i] = Float(state) / Float(UInt32.max) * 2 - 1
    }
    var mic = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let d = 500 - i / drift
        if i >= d { mic[i] = 0.3 * x[i - d] }
    }

    var aec = EchoCanceller()
    aec.filterLength = 128
    aec.blockLength = 16_000
    aec.refineRadius = 64

    func lastBlockResidual(_ out: [Float]) -> Float {
        var e: Float = 0
        for i in (n - 16_000)..<n { e += out[i] * out[i] }
        return e
    }
    let echo = lastBlockResidual(mic)

    // Par blocs : le ré-alignement suit la dérive, l'écho reste annulé jusqu'au bout.
    #expect(lastBlockResidual(aec.cancel(mic: mic, reference: x, maxLag: 600)) < 0.2 * echo)

    // Contre-épreuve : en un seul bloc (alignement unique), la dérive fait échouer l'annulation.
    aec.blockLength = n
    #expect(lastBlockResidual(aec.cancel(mic: mic, reference: x, maxLag: 600)) > 0.5 * echo)
}
