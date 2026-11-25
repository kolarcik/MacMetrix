// Generates the MacMetrix app icon (all macOS sizes) into an .appiconset.
//   swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a)
}

/// Bar heights shared with the menu bar glyph (MetricViews.swift → AppGlyph).
let heights: [CGFloat] = [0.62, 0.38, 0.84, 0.70, 0.48]
let colors: [(NSColor, NSColor)] = [
    (hex(0x2563EB), hex(0x60A5FA)), // CPU
    (hex(0x9333EA), hex(0xC084FC)), // GPU
    (hex(0xEA8A0C), hex(0xFCD34D)), // RAM
    (hex(0xDB2777), hex(0xF472B6)), // Disk
    (hex(0x16A34A), hex(0x4ADE80)), // Net
]

func drawIcon(in ctx: CGContext) {
    let canvas: CGFloat = 1024
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(hex(0x161B2C).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [hex(0x323B55).cgColor, hex(0x0D111D).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    // Soft highlight at the top
    let glow = CGGradient(colorsSpace: nil, colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: canvas / 2, y: body.maxY), startRadius: 0,
                           endCenter: CGPoint(x: canvas / 2, y: body.maxY), endRadius: 620, options: [])

    // Plot area
    let left: CGFloat = 214, right: CGFloat = 810, base: CGFloat = 236, maxH: CGFloat = 540
    let count = CGFloat(heights.count)
    let barW: CGFloat = 86
    let gap = (right - left - count * barW) / (count - 1)

    // Grid lines
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
    ctx.setLineWidth(4)
    for f in [0.25, 0.5, 0.75, 1.0] as [CGFloat] {
        ctx.move(to: CGPoint(x: left - 20, y: base + maxH * f))
        ctx.addLine(to: CGPoint(x: right + 20, y: base + maxH * f))
    }
    ctx.strokePath()

    var tops: [CGPoint] = []
    for (i, h) in heights.enumerated() {
        let x = left + CGFloat(i) * (barW + gap)
        // Track
        let track = CGPath(roundedRect: CGRect(x: x, y: base, width: barW, height: maxH), cornerWidth: 24, cornerHeight: 24, transform: nil)
        ctx.addPath(track)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
        ctx.fillPath()
        // Bar
        let rect = CGRect(x: x, y: base, width: barW, height: maxH * h)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.clip()
        let g = CGGradient(colorsSpace: nil, colors: [colors[i].0.cgColor, colors[i].1.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        ctx.restoreGState()
        tops.append(CGPoint(x: rect.midX, y: rect.maxY + 34))
    }

    // Pulse line over the bars
    let line = CGMutablePath()
    line.move(to: CGPoint(x: left - 30, y: tops[0].y - 60))
    line.addLine(to: tops[0])
    for i in 1..<tops.count {
        let p0 = tops[i - 1], p1 = tops[i]
        let mx = (p0.x + p1.x) / 2
        line.addCurve(to: p1, control1: CGPoint(x: mx, y: p0.y), control2: CGPoint(x: mx, y: p1.y))
    }
    line.addLine(to: CGPoint(x: right + 30, y: tops.last!.y + 40))
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.addPath(line)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
    for p in tops {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34))
    }
    ctx.restoreGState()

    // Thin inner border
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(4)
    ctx.strokePath()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: cg)
    ctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int, String)] = [
    ("16x16", 1, "1x"), ("16x16", 2, "2x"), ("32x32", 1, "1x"), ("32x32", 2, "2x"),
    ("128x128", 1, "1x"), ("128x128", 2, "2x"), ("256x256", 1, "1x"), ("256x256", 2, "2x"),
    ("512x512", 1, "1x"), ("512x512", 2, "2x"),
]
var images: [[String: String]] = []
for (size, scale, scaleName) in specs {
    let px = Int(size.split(separator: "x")[0])! * scale
    let file = "icon_\(size)@\(scaleName).png"
    try render(size: px).write(to: outDir.appendingPathComponent(file))
    images.append(["idiom": "mac", "size": size, "scale": scaleName, "filename": file])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("Icon written to \(outDir.path)")
