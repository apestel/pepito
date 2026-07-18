import Foundation
import AVFoundation
import Accelerate
import os
import CaptureKit

/// Analyse spectrale live (FFT) des deux sources, pour un rendu spectrogramme.
///
/// Les callbacks de capture (thread audio temps-réel) ne font qu'**accumuler** les échantillons dans
/// une fenêtre glissante par source (`push`). Le calcul FFT — plus coûteux — est fait dans `sample()`,
/// appelé à cadence d'affichage (~30 Hz) depuis une tâche de fond dédiée (hors thread audio ET hors
/// MainActor). `sample()` est mono-thread (une seule tâche l'appelle), donc le `FFTSetup` réutilisé
/// n'est jamais partagé.
final class SpectrumMeter: @unchecked Sendable {
    static let fftSize = 1024
    static let bands = 64   // bins de fréquence affichés (moyenne des 512 bins réels)

    private struct Src { var window = [Float]() }
    private let state = OSAllocatedUnfairLock(initialState: (mic: Src(), system: Src()))

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let hann: [Float]

    init() {
        log2n = vDSP_Length(log2(Float(Self.fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&w, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        hann = w
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Thread audio : ajoute les échantillons mono du buffer à la fenêtre glissante (bornée à fftSize).
    func push(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        guard let incoming = Self.monoTail(buffer, count: Self.fftSize) else { return }
        state.withLock { st in
            if source == .microphone { Self.appendWindow(&st.mic.window, incoming) }
            else { Self.appendWindow(&st.system.window, incoming) }
        }
    }

    /// Boucle UI : renvoie une colonne de spectre (bands valeurs 0…1) par source.
    func sample() -> (mic: [Float], system: [Float]) {
        let (micWin, sysWin) = state.withLock { ($0.mic.window, $0.system.window) }
        return (spectrum(micWin), spectrum(sysWin))
    }

    // MARK: - Privé

    private static func appendWindow(_ window: inout [Float], _ incoming: [Float]) {
        window.append(contentsOf: incoming)
        if window.count > fftSize { window.removeFirst(window.count - fftSize) }
    }

    /// Derniers `count` échantillons du canal 0 en Float (gère float32 et int16).
    private static func monoTail(_ buffer: AVAudioPCMBuffer, count: Int) -> [Float]? {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return nil }
        let take = min(n, count)
        let start = n - take
        var out = [Float](repeating: 0, count: take)
        if let ch = buffer.floatChannelData {
            let p = ch[0]
            for i in 0..<take { out[i] = p[start + i] }
        } else if let ch = buffer.int16ChannelData {
            let p = ch[0]
            for i in 0..<take { out[i] = Float(p[start + i]) / 32768 }
        } else {
            return nil
        }
        return out
    }

    private func spectrum(_ signal: [Float]) -> [Float] {
        guard signal.count == Self.fftSize else { return [Float](repeating: 0, count: Self.bands) }
        let half = Self.fftSize / 2

        // Fenêtrage Hann (réduit les fuites spectrales).
        var windowed = [Float](repeating: 0, count: Self.fftSize)
        vDSP_vmul(signal, 1, hann, 1, &windowed, 1, vDSP_Length(Self.fftSize))

        // FFT réelle : signal réel empaqueté en split-complexe (ctoz), magnitudes = |FFT|.
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let cplx = raw.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(cplx.baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        return bands(from: magnitudes)
    }

    /// Regroupe les `half` bins en `bands` (moyenne) puis mappe l'amplitude en échelle dB → [0,1].
    private func bands(from mags: [Float]) -> [Float] {
        let half = mags.count
        let per = max(1, half / Self.bands)
        var out = [Float](repeating: 0, count: Self.bands)
        for b in 0..<Self.bands {
            let lo = b * per
            let hi = min(half, lo + per)
            guard lo < hi else { continue }
            var sum: Float = 0
            for k in lo..<hi { sum += mags[k] }
            let mag = sum / Float(hi - lo) / Float(Self.fftSize)
            // ponytail: plancher -70 dB et plage 70 dB = knobs de calibration visuelle.
            let db = 20 * log10f(mag + 1e-7)
            out[b] = max(0, min(1, (db + 70) / 70))
        }
        return out
    }
}
