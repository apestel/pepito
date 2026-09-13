import Foundation
import Accelerate

/// Annulation d'écho acoustique par **signal de référence** (AEC), hors-ligne.
///
/// Le micro capte `ta_voix(t) + h * système(t) + bruit` : ta voix PLUS un écho de la sortie système
/// (bleed HP), coloré par le trajet HP→pièce→micro `h`. Connaissant la référence propre (audio
/// système capté par ScreenCaptureKit), un **filtre adaptatif NLMS** estime `h` en continu et
/// soustrait l'écho → il reste ta voix seule. DSP en amont de la transcription ; ne touche pas la sortie.
///
/// Robustesse réunions réelles : traitement par **blocs** avec ré-estimation du délai à chaque bloc
/// (micro et tap système vivent sur deux horloges — la dérive cumulée sur 45–60 min sortirait
/// l'écho de la fenêtre du filtre) et garde **double-talk** (Geigel) qui fige l'adaptation quand la
/// voix proche parle par-dessus l'écho (sinon le filtre diverge et ronge la voix). Limite assumée
/// (v1) : filtre linéaire (les non-linéarités du HP laissent un résidu).
struct EchoCanceller {
    var filterLength: Int = 1024          // ponytail: 64 ms @16k — allonger si écho réverbérant
    var stepSize: Float = 0.3             // μ NLMS — baisser si instable, monter si adaptation lente
    var regularization: Float = 1e-6
    var referenceEnergyFloor: Float = 1e-5 // pas d'adaptation quand la référence est quasi muette
    var blockLength: Int = 160_000        // 10 s @16k — période de ré-alignement du délai (dérive)
    var refineRadius: Int = 800           // ±50 ms @16k : recherche du délai autour du bloc précédent
    // ponytail: Geigel — pic|mic| > 0.5·pic|réf| ⇒ voix proche active, adaptation figée. Suppose un
    // écho ≥ 6 dB sous la référence (vrai à volume HP raisonnable) ; détecteur à cohérence si besoin.
    var doubleTalkThreshold: Float = 0.5
    var peakDecay: Float = 0.999          // pics glissants ~60 ms @16k pour la détection double-talk

    /// AEC complète par blocs : estime le délai mic↔référence bloc par bloc (plein `±maxLag` au
    /// premier bloc où la référence est audible, `±refineRadius` autour du délai précédent ensuite),
    /// aligne avec une avance de `filterLength/4` (tolère la dérive négative intra-bloc), annule en
    /// conservant les poids NLMS d'un bloc à l'autre.
    func cancel(mic: [Float], reference: [Float], maxLag: Int) -> [Float] {
        guard !mic.isEmpty, !reference.isEmpty else { return mic }
        let maxLag = max(0, maxLag)
        let window = min(blockLength, 48_000)
        let lead = filterLength / 4
        var out = [Float]()
        out.reserveCapacity(mic.count)
        var weights = [Float](repeating: 0, count: filterLength)
        var delay = 0
        var locked = false
        var b0 = 0
        while b0 < mic.count {
            let b1 = min(b0 + blockLength, mic.count)
            // Ré-estime le délai seulement si la référence est audible sur ce bloc — sinon la
            // corrélation n'est que du bruit et ferait sauter l'alignement.
            if Self.meanSquare(reference, from: b0, count: min(b1, reference.count) - b0) > referenceEnergyFloor {
                let lags = locked ? (delay - refineRadius)...(delay + refineRadius) : -maxLag...maxLag
                delay = Self.estimateDelay(mic: mic, reference: reference, lags: lags, offset: b0, window: window)
                locked = true
            }
            let aligned = Self.shift(reference, by: delay - lead, from: b0, length: b1 - b0)
            out.append(contentsOf: process(mic: Array(mic[b0..<b1]), reference: aligned, weights: &weights))
            b0 = b1
        }
        return out
    }

    /// État conservé entre les blocs lus sur disque.
    struct State {
        var weights: [Float] = []
        var delay = 0
        var locked = false
    }

    /// Fenêtre de référence nécessaire autour du bloc micro, en coordonnées fichier.
    func referenceRange(offset: Int, count: Int, maxLag: Int, state: State) -> Range<Int> {
        let lags = state.locked ? (state.delay - refineRadius)...(state.delay + refineRadius) : -maxLag...maxLag
        let first = max(0, min(offset, offset - max(lags.upperBound, state.delay)))
        let last = max(offset + count, offset + count - min(lags.lowerBound, state.delay) + filterLength / 4)
        return first..<last
    }

    /// Même filtre que `cancel`, avec une référence limitée à `referenceRange`.
    func cancelBlock(mic: [Float], reference: [Float], referenceOffset: Int,
                     maxLag: Int, state: inout State) -> [Float] {
        if state.weights.isEmpty { state.weights = .init(repeating: 0, count: filterLength) }
        if Self.meanSquare(reference, from: referenceOffset,
                           count: min(mic.count, reference.count - referenceOffset)) > referenceEnergyFloor {
            let lags = state.locked ? (state.delay - refineRadius)...(state.delay + refineRadius) : -maxLag...maxLag
            state.delay = Self.estimateDelay(mic: mic, reference: reference, lags: lags,
                                            offset: 0, window: min(blockLength, 48_000),
                                            referenceOffset: referenceOffset)
            state.locked = true
        }
        let aligned = Self.shift(reference, by: state.delay - filterLength / 4,
                                 from: referenceOffset, length: mic.count)
        return process(mic: mic, reference: aligned, weights: &state.weights)
    }

    /// NLMS. `reference` déjà alignée temporellement sur `mic` (même longueur) ; `weights` (taille
    /// `filterLength`) persiste entre appels pour enchaîner les blocs. Renvoie l'erreur (= micro
    /// débarrassé de l'écho estimé), échantillon par échantillon.
    func process(mic: [Float], reference: [Float], weights: inout [Float]) -> [Float] {
        let n = mic.count
        let L = filterLength
        guard n > 0, reference.count == n, L > 0, weights.count == L else { return mic }

        // Référence préfixée de (L-1) zéros : le bloc padded[i ..< i+L] est le vecteur d'entrée du tap i.
        var padded = [Float](repeating: 0, count: L - 1 + n)
        padded.replaceSubrange((L - 1)..<(L - 1 + n), with: reference)

        var out = [Float](repeating: 0, count: n)
        // Pics glissants (max à décroissance exponentielle) pour le détecteur de double-talk.
        var micPeak: Float = 0
        var refPeak: Float = 0

        padded.withUnsafeBufferPointer { refPtr in
            mic.withUnsafeBufferPointer { micPtr in
                weights.withUnsafeMutableBufferPointer { wBuf in
                    out.withUnsafeMutableBufferPointer { outBuf in
                        let wp = wBuf.baseAddress!
                        let mp = micPtr.baseAddress!
                        let op = outBuf.baseAddress!
                        let N = vDSP_Length(L)
                        for i in 0..<n {
                            let xp = refPtr.baseAddress! + i   // xseg = padded[i ..< i+L]
                            var y: Float = 0
                            vDSP_dotpr(wp, 1, xp, 1, &y, N)    // écho estimé
                            let e = mp[i] - y
                            op[i] = e
                            micPeak = max(abs(mp[i]), micPeak * peakDecay)
                            refPeak = max(abs(xp[Int(N) - 1]), refPeak * peakDecay)
                            var norm: Float = 0
                            vDSP_svesq(xp, 1, &norm, N)
                            // Adapte seulement si écho présent ET pas de double-talk (Geigel) —
                            // sinon la voix proche fait diverger le filtre et se fait ronger.
                            if norm > referenceEnergyFloor, micPeak <= doubleTalkThreshold * refPeak {
                                var factor = stepSize * e / (norm + regularization)
                                vDSP_vsma(xp, 1, &factor, wp, 1, wp, 1, N)
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Délai maximisant la corrélation croisée normalisée mic↔référence, cherché dans [-maxLag, maxLag].
    static func estimateDelay(mic: [Float], reference: [Float], maxLag: Int, window: Int = 48000) -> Int {
        guard maxLag > 0 else { return 0 }
        return estimateDelay(mic: mic, reference: reference, lags: -maxLag...maxLag, offset: 0, window: window)
    }

    /// Variante fenêtrée : délai `lag ∈ lags` tel que `mic[offset+i] ≈ écho de reference[offset+i-lag]`,
    /// évalué sur `window` échantillons à partir de `offset`.
    static func estimateDelay(
        mic: [Float], reference: [Float], lags: ClosedRange<Int>, offset: Int, window: Int = 48000, referenceOffset: Int? = nil
    ) -> Int {
        let refOffset = referenceOffset ?? offset
        let n = min(window, mic.count - offset)
        var bestLag = lags.contains(0) ? 0 : lags.lowerBound
        guard n > 0 else { return bestLag }
        var bestScore: Float = -.greatestFiniteMagnitude
        mic.withUnsafeBufferPointer { m in
            reference.withUnsafeBufferPointer { r in
                for lag in lags {
                    let start = max(0, lag - refOffset)
                    let end = min(n, reference.count + lag - refOffset)
                    let count = end - start
                    guard count > n / 2 else { continue }
                    let mp = m.baseAddress! + offset + start
                    let rp = r.baseAddress! + refOffset + start - lag
                    var dot: Float = 0
                    vDSP_dotpr(mp, 1, rp, 1, &dot, vDSP_Length(count))
                    var energy: Float = 0
                    vDSP_svesq(rp, 1, &energy, vDSP_Length(count))
                    let score = dot / (energy.squareRoot() + 1e-9)
                    if score > bestScore { bestScore = score; bestLag = lag }
                }
            }
        }
        return bestLag
    }

    /// `result[n] = x[offset + n - delay]`, complété de zéros, tronqué/étendu à `length`.
    static func shift(_ x: [Float], by delay: Int, from offset: Int = 0, length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        for n in 0..<length {
            let idx = offset + n - delay
            if idx >= 0, idx < x.count { out[n] = x[idx] }
        }
        return out
    }

    /// Énergie moyenne (carré) de `count` échantillons à partir de `offset`.
    private static func meanSquare(_ x: [Float], from offset: Int, count: Int) -> Float {
        guard count > 0, offset >= 0, offset + count <= x.count else { return 0 }
        var e: Float = 0
        x.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + offset, 1, &e, vDSP_Length(count)) }
        return e / Float(count)
    }
}
