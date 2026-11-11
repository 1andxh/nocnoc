// Renders the nocnoc app icon into Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
//
// Drawn entirely in code (no SF Symbols: Apple's licence doesn't allow them
// in app icons). Follows the macOS icon grid: a 1024 canvas with an 824 pt
// continuous-corner ("squircle") body, leaving room for the system shadow.
// Motif: a frosted prompt card with Deny / Allow pills and a "knock" dot.
import AppKit
import SwiftUI

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()

func continuous(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// Draws the icon in a 1024×1024 coordinate space (origin bottom-left).
func draw(_ ctx: CGContext) {
    // Body: violet -> blue squircle.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = continuous(body, 185)
    linear(ctx, bodyPath, [rgb(0x8B6CF7), rgb(0x4F7BF6), rgb(0x2F6FE8)],
           from: CGPoint(x: 300, y: 924), to: CGPoint(x: 724, y: 100))

    // Glass highlight across the top half, and a thin light edge.
    linear(ctx, bodyPath, [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0.0)],
           from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 520))
    ctx.saveGState()
    ctx.addPath(continuous(body.insetBy(dx: 3, dy: 3), 182))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.35))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    // The prompt card, floating with a soft shadow.
    let card = CGRect(x: 222, y: 300, width: 580, height: 410)
    let cardPath = continuous(card, 78)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 60, color: rgb(0x1A1A5E, 0.45))
    ctx.addPath(cardPath)
    ctx.setFillColor(rgb(0xFFFFFF, 0.95))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, cardPath, [rgb(0xFFFFFF, 0.0), rgb(0xE9ECFF, 0.6)],
           from: CGPoint(x: 512, y: 710), to: CGPoint(x: 512, y: 300))

    // Two lines of "text".
    ctx.setFillColor(rgb(0x2B2F5C, 0.85))
    ctx.addPath(continuous(CGRect(x: 290, y: 588, width: 330, height: 46), 23)); ctx.fillPath()
    ctx.setFillColor(rgb(0x2B2F5C, 0.28))
    ctx.addPath(continuous(CGRect(x: 290, y: 516, width: 420, height: 34), 17)); ctx.fillPath()

    // Deny (quiet) and Allow (accent) pills.
    ctx.setFillColor(rgb(0x2B2F5C, 0.10))
    ctx.addPath(continuous(CGRect(x: 418, y: 366, width: 150, height: 72), 36)); ctx.fillPath()
    linear(ctx, continuous(CGRect(x: 586, y: 366, width: 156, height: 72), 36),
           [rgb(0x8B6CF7), rgb(0x4F7BF6)], from: CGPoint(x: 586, y: 438), to: CGPoint(x: 742, y: 366))

    // The "knock": a coral dot on the card's corner, ringed in white.
    let dot = CGRect(x: 718, y: 628, width: 132, height: 132)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: dot.insetBy(dx: -14, dy: -14))
    linear(ctx, CGPath(ellipseIn: dot, transform: nil), [rgb(0xFF8A6B), rgb(0xFF5A5F)],
           from: CGPoint(x: dot.minX, y: dot.maxY), to: CGPoint(x: dot.maxX, y: dot.minY))
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
// A 1024 preview, handy for reviewing the design.
try png(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

// Asset catalog (what Xcode-built apps ship, and what recent macOS reads
// first). build-app.sh compiles it into Assets.car with actool.
let appiconset = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.removeItem(at: appiconset)
try FileManager.default.createDirectory(at: appiconset, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try png(size: base * scale).write(to: appiconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: appiconset.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: [.prettyPrinted])
    .write(to: root.appendingPathComponent("Resources/Assets.xcassets/Contents.json"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
