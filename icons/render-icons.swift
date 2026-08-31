// render-icons.swift -- draw the Screen Switch icon set with CoreGraphics.
//
// The menu bar templates are drawn on one 18x18 glyph grid, the same grid the
// design canvas uses. The app icon is not: it is full bleed, for the reason
// given above drawAppIcon. What the two share is the diagonal.
// Run with: swift icons/render-icons.swift
//
// Then rebuild the icns, which is what the bundle carries:
//   iconutil -c icns icons/AppIcon.iconset -o icons/AppIcon.icns

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
// The app icon fills the canvas, so its bezel is drawn thinner than the menu
// bar's: at the template's 1.5 the same stroke would read as a picture frame
// rather than the edge of a screen.
let appStrokeW: CGFloat = 0.9

func innerRect(_ lineWidth: CGFloat) -> CGRect {
    frame.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
}

// Half-plane through the inner rectangle's corners. In CoreGraphics y grows
// upward, so "upper" left is the corner at max-y.
func halfPlane(_ half: Half, _ inner: CGRect) -> CGPath? {
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
               unlit: CGColor?, lineWidth: CGFloat = strokeW) {
    let inner = innerRect(lineWidth)
    let innerR = frameR - lineWidth / 2
    if let clip = halfPlane(half, inner) {
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerR,
                           cornerHeight: innerR, transform: nil))
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }
    // The unlit half, painted rather than left open. Without the tile behind it
    // the icon has no background of its own, and a bare wedge on transparency
    // disappears into a light window; a filled screen reads either way.
    // Colour icon only -- a template image has no room for a second tone.
    if let unlit, half != .none,
       let clip = halfPlane(half == .upperLeft ? .lowerRight : .upperLeft, inner) {
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()
        ctx.addPath(CGPath(roundedRect: inner, cornerWidth: innerR,
                           cornerHeight: innerR, transform: nil))
        ctx.setFillColor(unlit)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: frameR,
                       cornerHeight: frameR, transform: nil))
    ctx.setStrokeColor(stroke)
    ctx.setLineWidth(lineWidth)
    ctx.strokePath()
}

// MARK: - Palette

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let accent = rgb(0x3C93F0), screenWhite = rgb(0xF2F5F8)
// The half of the screen nobody is using. Dark enough to hold the diagonal
// against the lit half, light enough not to read as a hole.
let screenDark = rgb(0x23282F)

// MARK: - App icon
//
// Full bleed, and no tile of its own. macOS composites any icon that does not
// fill its canvas onto a light rounded tile and pads it -- so "the glyph on
// transparency" is not an option that exists: it comes back as a small picture
// in a grey frame. An icon that fills the canvas is masked to the system shape
// instead, which is the only way to have no padding at all.
//
// What that costs is the bezel: the screen's white outline and its rounded
// corners fall outside the mask. The diagonal is what survives, and it is the
// half that carries the meaning -- lit corner is whoever owns the monitor,
// the same split the menu bar template draws.

func drawAppIcon(_ ctx: CGContext, size: CGFloat) {
    ctx.setFillColor(screenDark)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    // The lit half, corner to corner. Bottom-left to top-right, matching the
    // glyph's .upperLeft: this Mac has the monitor.
    let p = CGMutablePath()
    p.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: size, y: size),
                         CGPoint(x: 0, y: size)])
    p.closeSubpath()
    ctx.addPath(p)
    ctx.setFillColor(accent)
    ctx.fillPath()

    // A hairline along the split, so the two halves read as an edge rather
    // than as two flat shapes that happen to meet.
    ctx.move(to: CGPoint(x: 0, y: 0))
    ctx.addLine(to: CGPoint(x: size, y: size))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
    ctx.setLineWidth(size * 0.012)
    ctx.strokePath()
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
    drawGlyph(ctx, half: half, fill: black, stroke: black, unlit: nil)
    ctx.endPDFPage()
    ctx.closePDF()
    data.write(toFile: path, atomically: true)
}

writeTemplatePDF(.upperLeft, to: "\(out)/MenuExtended.pdf")
writeTemplatePDF(.lowerRight, to: "\(out)/MenuMirrored.pdf")
writeTemplatePDF(.none, to: "\(out)/MenuUnreachable.pdf")

print("rendered into \(out)")
