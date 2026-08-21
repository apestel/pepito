#!/usr/bin/env swift
// Génère Packaging/Pepito.icns — bulle de dialogue + transcript, dont la dernière ligne est cochée
// (« la réunion devient des actions »). Tout est dessiné en Core Graphics : aucun outil de design,
// aucune dépendance, régénérable. Relancer uniquement si le dessin change :
//
//     swift Packaging/make-icon.swift
//
// Produit .build/Pepito.iconset/ (intermédiaire) et Packaging/Pepito.icns (commité).

import AppKit

let S = 1024.0                      // canevas de référence ; tout est exprimé dans ce repère
let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let root = pkg.deletingLastPathComponent()
let iconset = root.appending(path: ".build/Pepito.iconset")

func rounded(_ r: CGRect, _ radius: Double) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(into ctx: CGContext) {
    // Fond : squircle dégradé ambre → orange. La marge de 76 est le retrait d'icône macOS usuel.
    let plate = rounded(CGRect(x: 76, y: 76, width: 872, height: 872), 195)
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 1.00, green: 0.75, blue: 0.22, alpha: 1),
        CGColor(red: 0.93, green: 0.38, blue: 0.06, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 76, y: 948), end: CGPoint(x: 948, y: 76),
                           options: [])
    ctx.restoreGState()

    // Bulle de dialogue (corps + queue en bas à gauche), blanc cassé.
    let bubble = CGMutablePath()
    bubble.addPath(rounded(CGRect(x: 196, y: 320, width: 632, height: 452), 92))
    bubble.move(to: CGPoint(x: 296, y: 340))
    bubble.addLine(to: CGPoint(x: 286, y: 196))
    bubble.addLine(to: CGPoint(x: 430, y: 340))
    bubble.closeSubpath()
    ctx.setFillColor(CGColor(red: 1, green: 0.99, blue: 0.97, alpha: 1))
    ctx.addPath(bubble)
    ctx.fillPath()

    // Deux lignes de « transcript » (gris chaud), puis la ligne cochée (orange) : l'action.
    ctx.setFillColor(CGColor(red: 0.80, green: 0.74, blue: 0.68, alpha: 1))
    for (y, w) in [(650.0, 468.0), (536.0, 372.0)] {
        ctx.addPath(rounded(CGRect(x: 268, y: y, width: w, height: 52), 26))
    }
    ctx.fillPath()

    let accent = CGColor(red: 0.90, green: 0.33, blue: 0.05, alpha: 1)
    ctx.setFillColor(accent)
    ctx.addPath(rounded(CGRect(x: 268, y: 396, width: 96, height: 96), 30))       // case
    ctx.addPath(rounded(CGRect(x: 400, y: 418, width: 300, height: 52), 26))      // libellé
    ctx.fillPath()

    // Coche blanche dans la case.
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(22)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 293, y: 444))
    ctx.addLine(to: CGPoint(x: 311, y: 421))
    ctx.addLine(to: CGPoint(x: 341, y: 466))
    ctx.strokePath()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    ctx.scaleBy(x: Double(size) / S, y: Double(size) / S)   // dessin vectoriel, net à toute taille
    draw(into: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
// Aperçu à taille réelle pour relecture humaine avant de figer le .icns.
try png(size: 1024).write(to: root.appending(path: ".build/icon-preview.png"))

let icns = pkg.appending(path: "Pepito.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { exit(p.terminationStatus) }
print("Écrit : \(icns.path)")
print("Aperçu : \(root.appending(path: ".build/icon-preview.png").path)")
