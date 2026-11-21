// Draws Dusk's app icon and writes it as an .icns.
// Run from the project folder:  swift Tools/make-icon.swift Resources/AppIcon.icns

import AppKit

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Draws the icon on a 1024-point canvas, scaled to `size` pixels.
func draw(_ ctx: CGContext, size: CGFloat) {
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    // Standard macOS icon grid: an 824-point rounded tile centred on the canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x0C0E2A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // A setting sun on the horizon, matching the menu bar's sun.horizon symbol.
    let horizon: CGFloat = 400
    let sun = CGPoint(x: 512, y: horizon)
    let sunRadius: CGFloat = 200
    let cream = rgb(0xFFE3A6)

    // Dusk sky: indigo overhead, through purple and rose, to orange at the horizon.
    let sky = CGGradient(colorsSpace: sRGB,
                         colors: [rgb(0x1B1F55), rgb(0x4A3378), rgb(0xC2577A), rgb(0xF59A4A)] as CFArray,
                         locations: [0, 0.55, 0.85, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: horizon), options: [])

    // Dark water below the horizon.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: horizon - tile.minY))
    let water = CGGradient(colorsSpace: sRGB, colors: [rgb(0x2A1F4D), rgb(0x0D0F2B)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(water, start: CGPoint(x: 512, y: horizon), end: CGPoint(x: 512, y: tile.minY), options: [])
    ctx.restoreGState()

    // Warm glow around the sun.
    let glow = CGGradient(colorsSpace: sRGB, colors: [rgb(0xFFB45A, 0.45), rgb(0xFFB45A, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 430, options: [])

    // A few early stars.
    ctx.setFillColor(rgb(0xFFF3DC, 0.85))
    for (x, y, r) in [(255.0, 835.0, 8.0), (335.0, 770.0, 5.0), (770.0, 850.0, 7.0), (845.0, 775.0, 5.0), (660.0, 870.0, 4.0)] {
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // Rays.
    ctx.setLineCap(.round)
    ctx.setStrokeColor(cream)
    ctx.setLineWidth(30)
    for degrees in [18.0, 54.0, 90.0, 126.0, 162.0] {
        let a = degrees * .pi / 180
        ctx.move(to: CGPoint(x: sun.x + cos(a) * 252, y: sun.y + sin(a) * 252))
        ctx.addLine(to: CGPoint(x: sun.x + cos(a) * 322, y: sun.y + sin(a) * 322))
    }
    ctx.strokePath()

    // The half-sun, glowing amber.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xFFA940, 0.6))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState()
    ctx.clip(to: CGRect(x: tile.minX, y: horizon, width: tile.width, height: tile.maxY - horizon))
    ctx.addEllipse(in: CGRect(x: sun.x - sunRadius, y: sun.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2))
    ctx.clip()
    let amber = CGGradient(colorsSpace: sRGB, colors: [rgb(0xFFE7A8), rgb(0xF7A142)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(amber, start: CGPoint(x: sun.x, y: sun.y + sunRadius), end: sun, options: [])
    ctx.restoreGState()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Horizon line right across the tile (its rounded outline trims the ends), and the sun's shimmer on the water.
    for (y, halfWidth, lineWidth, alpha) in [(horizon, 440.0, 22.0, 0.95), (330.0, 132.0, 16.0, 0.45), (270.0, 72.0, 14.0, 0.3)] {
        ctx.setStrokeColor(rgb(0xFFE3A6, alpha))
        ctx.setLineWidth(lineWidth)
        ctx.move(to: CGPoint(x: sun.x - halfWidth, y: y))
        ctx.addLine(to: CGPoint(x: sun.x + halfWidth, y: y))
        ctx.strokePath()
    }

    // Faint edge highlight so the tile reads on a dark Dock.
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
}

func writePNG(pixels: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, size: CGFloat(pixels))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    writePNG(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
