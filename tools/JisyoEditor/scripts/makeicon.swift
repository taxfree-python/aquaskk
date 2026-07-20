// Generates the 候補順 (Kohojun) app icon as an .iconset directory.
// Usage: swift scripts/makeicon.swift <output.iconset>
// Then:  iconutil -c icns <output.iconset> -o Resources/Kohojun.icns
//
// Motif: the SKK conversion marker ▽ next to a candidate list whose top
// entry is highlighted — "this app decides which candidate comes first".

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let master: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1.0) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Default is the blue accent; pass "mono" as a second argument for a pure
// black-and-white rendition (white marks on a neutral near-black plate).
let mono = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "mono"

let accent = mono ? color(0xF5F5F5) : color(0x4DA3FF)
let barGray = color(0xFFFFFF, mono ? 0.32 : 0.28)
let plateTop = mono ? color(0x232323) : color(0x2A303D)
let plateBottom = mono ? color(0x0E0E0E) : color(0x151922)

func drawMaster(into ctx: CGContext) {
    let s = master

    // Background squircle on the Big Sur icon grid: 824pt square, centered,
    // with the canonical ~22.5% corner radius. Everything outside stays
    // transparent so macOS renders the standard drop shadow itself.
    let bg = CGRect(x: 100, y: 100, width: s - 200, height: s - 200)
    let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [plateTop, plateBottom] as CFArray,
        locations: [0, 1]
    )!
    // CG origin is bottom-left; start from the top of the icon.
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: s / 2, y: s - 100),
        end: CGPoint(x: s / 2, y: 100),
        options: []
    )
    ctx.restoreGState()

    // Faint inner rim to lift the plate off dark backgrounds.
    ctx.saveGState()
    ctx.addPath(CGPath(
        roundedRect: bg.insetBy(dx: 3, dy: 3),
        cornerWidth: 182, cornerHeight: 182, transform: nil
    ))
    ctx.setStrokeColor(color(0xFFFFFF, 0.07))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    // ▽ marker: outlined downward triangle, rounded joins, left of center.
    // (CG y-axis points up: "top" edge of the glyph is at high y.)
    ctx.saveGState()
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(58)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    let triTopY: CGFloat = 660
    let triBottomY: CGFloat = 396
    let triPath = CGMutablePath()
    triPath.move(to: CGPoint(x: 268, y: triTopY))
    triPath.addLine(to: CGPoint(x: 512, y: triTopY))
    triPath.addLine(to: CGPoint(x: 390, y: triBottomY))
    triPath.closeSubpath()
    ctx.addPath(triPath)
    ctx.strokePath()
    ctx.restoreGState()

    // Candidate list: three bars, the first one accent-highlighted and wider.
    // Vertically aligned with the triangle's optical span.
    let barX: CGFloat = 596
    let barHeight: CGFloat = 64
    let radius = barHeight / 2
    let rows: [(y: CGFloat, width: CGFloat, fill: CGColor)] = [
        (628, 256, accent),
        (496, 190, barGray),
        (364, 190, barGray),
    ]
    for row in rows {
        let rect = CGRect(x: barX, y: row.y, width: row.width, height: barHeight)
        ctx.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: radius, cornerHeight: radius, transform: nil
        ))
        ctx.setFillColor(row.fill)
        ctx.fillPath()
    }
}

func renderPNG(size: Int, to url: URL, masterImage: CGImage) {
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(masterImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("failed to write \(url.path)")
    }
}

// MARK: - main

guard CommandLine.arguments.count >= 2 else {
    print("usage: swift scripts/makeicon.swift <output.iconset>")
    exit(64)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let masterCtx = CGContext(
    data: nil, width: Int(master), height: Int(master),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
drawMaster(into: masterCtx)
let masterImage = masterCtx.makeImage()!

let entries: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for entry in entries {
    renderPNG(size: entry.size, to: outDir.appendingPathComponent(entry.name), masterImage: masterImage)
}
print("wrote \(entries.count) images to \(outDir.path)")
