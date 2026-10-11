import AppKit

// Génère AppIcon.icns : `swift icon.swift` (à relancer seulement si on change le dessin).

let size = 1024.0
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func rgb(_ hex: Int, _ a: Double = 1) -> NSColor {
    NSColor(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: a)
}
func circle(_ r: Double, _ cx: Double = size / 2, _ cy: Double = size / 2) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
}

// Fond : carré arrondi aux proportions des icônes macOS, dégradé orange -> rose -> violet.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(colors: [rgb(0x5B2EE5), rgb(0xE93B81), rgb(0xFFA63D)])!.draw(in: tile, angle: 65)

// Vinyle, avec ombre portée, sillons et reflets.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
shadow.shadowBlurRadius = 40
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.set()
rgb(0x121214).setFill()
circle(310).fill()
NSGraphicsContext.restoreGraphicsState()

for r in stride(from: 150.0, through: 295, by: 9) {
    NSColor.white.withAlphaComponent(r.truncatingRemainder(dividingBy: 27) < 9 ? 0.13 : 0.06).setStroke()
    let groove = circle(r)
    groove.lineWidth = 2
    groove.stroke()
}
NSGraphicsContext.saveGraphicsState()
circle(310).addClip()
for angle in [35.0, 215.0] {
    let wedge = NSBezierPath()
    wedge.move(to: NSPoint(x: size / 2, y: size / 2))
    wedge.appendArc(withCenter: NSPoint(x: size / 2, y: size / 2), radius: 310, startAngle: angle - 14, endAngle: angle + 14)
    wedge.close()
    NSColor.white.withAlphaComponent(0.10).setFill()
    wedge.fill()
}
NSGraphicsContext.restoreGraphicsState()

// Étiquette centrale avec une note de musique.
NSGradient(colors: [rgb(0xFFD166), rgb(0xFF7A3D)])!.draw(in: circle(128), angle: 65)
let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!
    .withSymbolConfiguration(.init(pointSize: 150, weight: .heavy).applying(.init(paletteColors: [.white])))!
note.draw(
    in: NSRect(x: (size - note.size.width) / 2 - 6, y: (size - note.size.height) / 2, width: note.size.width, height: note.size.height))

NSGraphicsContext.current?.flushGraphics()
let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let set = dir.appendingPathComponent("build/AppIcon.iconset")
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let master = set.appendingPathComponent("icon_512x512@2x.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)

func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512)] {
    run("/usr/bin/sips", ["-z", "\(px)", "\(px)", master.path, "--out", set.appendingPathComponent("icon_\(name).png").path])
}
run("/usr/bin/iconutil", ["-c", "icns", set.path, "-o", dir.appendingPathComponent("AppIcon.icns").path])
print("OK : AppIcon.icns")
