// render-icons.swift -- draw the Screen Switch icon set with CoreGraphics.
//
// Everything is derived from one 18x18 glyph grid, the same grid the design
// canvas uses, so the app icon and the menu bar template never drift apart.
// Run with: swift icons/render-icons.swift

import AppKit
import CoreGraphics
import Foundation

// MARK: - The glyph
//
// A screen, split corner to corner. The lit half says who owns the monitor:
// upper-left is this Mac (extended), lower-right is the other machine
// (mirrored), neither is "no answer over DDC".

enum Half { case upperLeft, lowerRight, none }

let G: CGFloat = 18          // glyph grid
let strokeW: CGFloat = 1.5
// Frame path centreline; the fill sits exactly inside it, so the two meet
// without a seam and the split stays the only open edge.
let frame = CGRect(x: 1.5, y: 3.5, width: 15, height: 11)
let frameR: CGFloat = 2.1
let inner = frame.insetBy(dx: strokeW / 2, dy: strokeW / 2)
let innerR = frameR - strokeW / 2

// Half-plane through the inner rectangle's corners. In CoreGraphics y grows
// upward, so "upper" left is the corner at max-y.
func halfPlane(_ half: Half) -> CGPath? {
    let bl = CGPoint(x: inner.minX, y: inner.minY)
    let tr = CGPoint(x: inner.maxX, y: inner.maxY)
    let p = CGMutablePath()
    switch half {
    case .upperLeft:
        p.addLines(between: [bl, tr, CGPoint(x: tr.x, y: G + 4),
                             CGPoint(x: -4, y: G + 4), CGPoint(x: -4, y: bl.y)])
    case .lowerRight:
        p.addLines(between: [bl, tr, CGPoint(x: G + 4, y: tr.y),
                             CGPoint(x: G + 4, y: -4), CGPoint(x: bl.x, y: -4)])
    case .none:
        return nil
    }
    p.closeSubpath()
    return p
}

func drawGlyph(_ ctx: CGContext, half: Half, fill: CGColor, stroke: CGColor,
               ghostOtherHalf: Bool) {
    if let clip = halfPlane(half) {
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerR,
                           cornerHeight: innerR, transform: nil))
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }
    // A whisper of light in the unlit half so the shape still reads as a
    // screen rather than a wedge. Colour icon only -- a template image has no
    // room for a second tone.
    if ghostOtherHalf, half != .none,
       let clip = halfPlane(half == .upperLeft ? .lowerRight : .upperLeft) {
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerR,
                           cornerHeight: innerR, transform: nil))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.07))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: frameR,
                       cornerHeight: frameR, transform: nil))
    ctx.setStrokeColor(stroke)
    ctx.setLineWidth(strokeW)
    ctx.strokePath()
}

// MARK: - Palette

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let tileTop = rgb(0x2E343C), tileBottom = rgb(0x13161B)
let accent = rgb(0x3C93F0), screenWhite = rgb(0xF2F5F8)

// MARK: - App icon

// Apple's macOS grid: on a 1024 canvas the body is 824 square with a 185.4
// corner, and the margin that leaves is where the shadow lives. Filling the
// canvas edge to edge renders about a quarter larger than every neighbour in
// the Dock -- measure any system icon and it comes back at 80% of its canvas.
let bodyRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 185.4 / 824.0

func drawAppIcon(_ ctx: CGContext, size: CGFloat) {
    let body = size * bodyRatio
    let r = body * cornerRatio
    let tile = CGRect(x: (size - body) / 2, y: (size - body) / 2,
                      width: body, height: body)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: r, cornerHeight: r,
                          transform: nil)

    // Shadow first, as a filled silhouette: sized to stay inside the margin
    // and weighted downward, the way the system icons are.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.034,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.34))
    ctx.addPath(tilePath)
    ctx.setFillColor(tileBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: space,
                          colors: [tileTop, tileBottom] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY),
                           end: CGPoint(x: 0, y: tile.minY), options: [])
    // Top edge catch-light, the one piece of relief on an otherwise flat tile.
    // Left to go sub-pixel at the small sizes rather than clamped to a full
    // unit, which at 16pt would be a sixteenth of the icon.
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.13))
    ctx.setLineWidth(body * 0.006)
    ctx.addPath(tilePath)
    ctx.strokePath()
    ctx.restoreGState()

    // Glyph at 62% of the body, optically centred.
    let scale = body * 0.62 / G
    ctx.saveGState()
    ctx.translateBy(x: (size - G * scale) / 2, y: (size - G * scale) / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.setLineWidth(strokeW)
    drawGlyph(ctx, half: .upperLeft, fill: accent, stroke: screenWhite,
              ghostOtherHalf: size >= 32)
    ctx.restoreGState()
}

// MARK: - Output

func context(_ px: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons"
let iconset = "\(out)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset,
                                         withIntermediateDirectories: true)

// The set iconutil expects: every size at 1x and 2x.
for (pt, name) in [(16, "16x16"), (32, "32x32"), (128, "128x128"),
                   (256, "256x256"), (512, "512x512")] {
    for scale in [1, 2] {
        let px = pt * scale
        let ctx = context(px)
        ctx.scaleBy(x: CGFloat(px) / CGFloat(pt), y: CGFloat(px) / CGFloat(pt))
        drawAppIcon(ctx, size: CGFloat(pt))
        let suffix = scale == 1 ? "" : "@2x"
        writePNG(ctx.makeImage()!, to: "\(iconset)/icon_\(name)\(suffix).png")
    }
}

// A flat 1024 for README and store listings.
let big = context(1024)
drawAppIcon(big, size: 1024)
writePNG(big.makeImage()!, to: "\(out)/AppIcon-1024.png")

// MARK: - Menu bar templates
//
// Vector PDF, so AppKit renders it crisp at whatever point size the menu bar
// asks for. Template images carry alpha only -- macOS supplies the colour for
// light, dark and the highlighted state, which is why nothing here is tinted.

func writeTemplatePDF(_ half: Half, to path: String) {
    var box = CGRect(x: 0, y: 0, width: G, height: G)
    let data = NSMutableData()
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    // Match the optical width of the SF Symbols it sits next to: wifi, battery
    // and friends run about 15.3pt wide in an 18pt box, the raw glyph 16.5.
    // The glyph is already centred on (9, 9), so scale about that.
    let k: CGFloat = 15.3 / 16.5
    ctx.translateBy(x: G / 2, y: G / 2)
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -G / 2, y: -G / 2)
    let black = CGColor(red: 0, green: 0, blue: 0, alpha: half == .none ? 0.45 : 1)
    drawGlyph(ctx, half: half, fill: black, stroke: black, ghostOtherHalf: false)
    ctx.endPDFPage()
    ctx.closePDF()
    data.write(toFile: path, atomically: true)
}

writeTemplatePDF(.upperLeft, to: "\(out)/MenuExtended.pdf")
writeTemplatePDF(.lowerRight, to: "\(out)/MenuMirrored.pdf")
writeTemplatePDF(.none, to: "\(out)/MenuUnreachable.pdf")

print("rendered into \(out)")
