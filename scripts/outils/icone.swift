// Dessine Resources/AppIcon.png : swift scripts/outils/icone.swift Resources/AppIcon.png
// Icône de Strapontin : un fauteuil de cinéma rouge à assise relevée, sous le halo de l'écran. 1024 × 1024.
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r/255, g/255, b/255, a])! }
func linear(_ colors: [CGColor], _ from: CGPoint, _ to: CGPoint, in path: CGPath) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!, start: from, end: to, options: [])
    ctx.restoreGState()
}
func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

// fond : carré arrondi façon macOS (marge de 100 px comme les icônes Apple), nuit de salle de cinéma
let inset: CGFloat = 100, side = S - 2 * inset
let tile = rr(inset, inset, side, side, side * 0.225)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.45))
ctx.addPath(tile); ctx.setFillColor(c(16, 14, 20)); ctx.fillPath()
ctx.restoreGState()
linear([c(34, 28, 40), c(12, 10, 15)], CGPoint(x: 0, y: S - inset), CGPoint(x: 0, y: inset), in: tile)
// halo de l'écran, en haut
ctx.saveGState(); ctx.addPath(tile); ctx.clip()
ctx.drawRadialGradient(CGGradient(colorsSpace: cs, colors: [c(255, 170, 60, 0.55), c(255, 140, 40, 0.0)] as CFArray, locations: [0, 1])!,
                       startCenter: CGPoint(x: S/2, y: S - inset + 40), startRadius: 0,
                       endCenter: CGPoint(x: S/2, y: S - inset + 40), endRadius: 520, options: [])
ctx.restoreGState()

// fauteuil, vu de face
let cx = S / 2
let backW: CGFloat = 400, backH: CGFloat = 430, backY: CGFloat = 330
let back = rr(cx - backW/2, backY, backW, backH, 120)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: c(0, 0, 0, 0.6))
ctx.addPath(back); ctx.setFillColor(c(120, 20, 24)); ctx.fillPath()
ctx.restoreGState()
linear([c(222, 56, 52), c(150, 24, 30), c(104, 14, 22)], CGPoint(x: cx, y: backY + backH), CGPoint(x: cx, y: backY), in: back)
// capitons : trois coutures verticales
ctx.saveGState(); ctx.addPath(back); ctx.clip()
for dx in [-backW/6, backW/6] {
    ctx.setStrokeColor(c(70, 6, 12, 0.55)); ctx.setLineWidth(10)
    ctx.move(to: CGPoint(x: cx + dx, y: backY + 40)); ctx.addLine(to: CGPoint(x: cx + dx, y: backY + backH - 40)); ctx.strokePath()
    ctx.setStrokeColor(c(255, 120, 110, 0.18)); ctx.setLineWidth(4)
    ctx.move(to: CGPoint(x: cx + dx + 7, y: backY + 40)); ctx.addLine(to: CGPoint(x: cx + dx + 7, y: backY + backH - 40)); ctx.strokePath()
}
// reflet du haut
ctx.drawRadialGradient(CGGradient(colorsSpace: cs, colors: [c(255, 200, 170, 0.35), c(255, 200, 170, 0)] as CFArray, locations: [0, 1])!,
                       startCenter: CGPoint(x: cx, y: backY + backH - 20), startRadius: 0,
                       endCenter: CGPoint(x: cx, y: backY + backH - 20), endRadius: 230, options: [])
ctx.restoreGState()

// accoudoirs
for side in [-1.0, 1.0] as [CGFloat] {
    let x = cx + side * (backW/2 + 34) - 38
    let arm = rr(x, 250, 76, 330, 34)
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: c(0, 0, 0, 0.55))
    ctx.addPath(arm); ctx.setFillColor(c(40, 36, 44)); ctx.fillPath(); ctx.restoreGState()
    linear([c(78, 72, 84), c(30, 27, 34)], CGPoint(x: 0, y: 580), CGPoint(x: 0, y: 250), in: arm)
    // dessus de l'accoudoir, bois chaud
    let top = rr(x - 6, 548, 88, 44, 22)
    linear([c(196, 120, 60), c(120, 66, 30)], CGPoint(x: 0, y: 592), CGPoint(x: 0, y: 548), in: top)
}

// assise relevée (le strapontin) : épaisse barre arrondie devant le bas du dossier
let seat = rr(cx - backW/2 + 18, 286, backW - 36, 118, 50)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: c(0, 0, 0, 0.6))
ctx.addPath(seat); ctx.setFillColor(c(150, 24, 30)); ctx.fillPath(); ctx.restoreGState()
linear([c(238, 74, 66), c(166, 30, 36), c(112, 16, 24)], CGPoint(x: 0, y: 404), CGPoint(x: 0, y: 286), in: seat)
// liseré doré de l'assise
ctx.addPath(rr(cx - backW/2 + 30, 298, backW - 60, 94, 42)); ctx.setStrokeColor(c(255, 186, 90, 0.55)); ctx.setLineWidth(5); ctx.strokePath()

// pied
let foot = rr(cx - 110, 200, 220, 56, 20)
linear([c(70, 64, 76), c(28, 25, 32)], CGPoint(x: 0, y: 256), CGPoint(x: 0, y: 200), in: foot)

// petit triangle « lecture » orange, brodé sur le dossier
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: c(255, 160, 50, 0.8))
let t = CGMutablePath()
let ty: CGFloat = backY + backH * 0.62
t.move(to: CGPoint(x: cx - 34, y: ty - 44)); t.addLine(to: CGPoint(x: cx - 34, y: ty + 44)); t.addLine(to: CGPoint(x: cx + 46, y: ty)); t.closeSubpath()
ctx.addPath(t); ctx.setFillColor(c(255, 166, 52)); ctx.fillPath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
