import Testing
import Foundation
import CoreGraphics
@testable import Pepito

/// Lit un pixel RGBA (alpha prémultiplié) de l'image, en coordonnées image (ligne 0 en haut).
@MainActor
private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let data = image.dataProvider!.data! as Data
    let i = y * image.bytesPerRow + x * 4
    return (data[i], data[i + 1], data[i + 2], data[i + 3])
}

// Le spectrogramme est composé à la main (mapping d'index, retournement de ligne, alpha
// prémultiplié) pour ne faire qu'un seul `ctx.draw` au lieu de 17 920 `ctx.fill` par frame.
@MainActor
@Test func heatmapPlacesSourcesAndRespectsThreshold() throws {
    // 2 colonnes × 4 bandes. Micro : bande 0 (basse fréquence) à fond sur la colonne 0.
    // Système : bande 3 (haute fréquence) à fond sur la colonne 1. Le reste sous le seuil.
    let sous = RecordingLevelsView.seuil / 2
    let mic = [[Float(1), sous, sous, sous], [sous, sous, sous, sous]]
    let system = [[sous, sous, sous, sous], [sous, sous, sous, Float(1)]]

    let image = try #require(RecordingLevelsView.heatmap(mic: mic, system: system))
    #expect(image.width == 2)
    #expect(image.height == 4)

    // Basses fréquences EN BAS : la bande 0 du micro atterrit sur la dernière ligne de l'image.
    let bas = pixel(image, x: 0, y: 3)
    #expect(bas.a == 255)
    #expect(bas.b > bas.r)          // bleu (.blue macOS ≈ 0, 0.478, 1)

    // Hautes fréquences en haut, sur la colonne de droite, en orange.
    let haut = pixel(image, x: 1, y: 0)
    #expect(haut.a == 255)
    #expect(haut.r > haut.b)        // orange (≈ 1, 0.584, 0)

    // Sous le seuil : cellule laissée transparente (le fond noir de la vue transparaît).
    #expect(pixel(image, x: 1, y: 3).a == 0)
    #expect(pixel(image, x: 0, y: 0).a == 0)
}

// Deux sources sur la même cellule : la seconde recouvre la première (source-over), comme les
// deux passes de `fill` d'origine.
@MainActor
@Test func heatmapCompositesOverlappingSources() throws {
    let plein = [[Float(1)]]
    let image = try #require(RecordingLevelsView.heatmap(mic: plein, system: plein))
    let p = pixel(image, x: 0, y: 0)
    #expect(p.a == 255)
    #expect(p.r > p.b)              // système (orange) au-dessus du micro (bleu)
}

// Sources de longueurs différentes : chacune reste étirée sur toute la largeur, sans déborder.
@MainActor
@Test func heatmapHandlesUnevenColumnCounts() throws {
    let court = [[Float(1)]]
    let long = [[Float](repeating: 1, count: 3), [Float](repeating: 1, count: 3)]
    let image = try #require(RecordingLevelsView.heatmap(mic: court, system: long))
    #expect(image.width == 2)       // max des deux
    #expect(image.height == 3)
    #expect(pixel(image, x: 0, y: 0).a == 255)
    #expect(pixel(image, x: 1, y: 2).a == 255)
}
