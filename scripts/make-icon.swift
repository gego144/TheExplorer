// Renders the app icon to Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the 1024pt master: a graphite tile, a mint chevron, and three size bars.
func drawIcon(in size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size / 1024
    NSGraphicsContext.current?.imageInterpolation = .high

    // Tile (macOS icon grid: 824pt body inset by 100pt, ~185pt corner radius).
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSGradient(starting: color(0x232933), ending: color(0x0D0F12))!.draw(in: tile, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    color(0x3DF5C0, 0.18).setStroke()
    tile.lineWidth = 4 * s
    tile.stroke()

    // Mint chevron.
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 262 * s, y: 652 * s))
    chevron.line(to: NSPoint(x: 400 * s, y: 512 * s))
    chevron.line(to: NSPoint(x: 262 * s, y: 372 * s))
    chevron.lineWidth = 64 * s
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    color(0x3DF5C0).setStroke()
    chevron.stroke()

    // Size bars: track plus a heat-coloured fill, like the file list.
    let bars: [(y: CGFloat, fill: CGFloat, hex: UInt32)] = [(612, 1.0, 0xF5603D), (488, 0.62, 0xF5D63D), (364, 0.3, 0x3DF5C0)]
    for bar in bars {
        let track = NSRect(x: 470 * s, y: bar.y * s, width: 330 * s, height: 50 * s)
        color(0x2A313B).setFill()
        NSBezierPath(roundedRect: track, xRadius: 25 * s, yRadius: 25 * s).fill()
        var filled = track
        filled.size.width = max(track.height, track.width * bar.fill)
        color(bar.hex).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 25 * s, yRadius: 25 * s).fill()
    }
    image.unlockFocus()
    return image
}

func pngData(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = drawIcon(in: 1024)
for points in [16, 32, 128, 256, 512] {
    try pngData(master, pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try pngData(master, pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try pngData(master, pixels: 512).write(to: FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-preview.png"))
print("Wrote \(output.path)")
