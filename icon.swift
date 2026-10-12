import AppKit
import SwiftUI

// Génère AppIcon.icns : `swift icon.swift` (à relancer seulement si on change le dessin).
// La platine en pixel art de la barre des menus, en couleurs rétro. La tuile entière est le plateau :
// un dessin plus petit posé sur une tuile sombre paraissait rétréci dans le Dock.

let art = [
    "...dddd.....aa.",
    ".dddddddd...aa.",
    ".ddggggdd...aa.",
    "ddgllllgdd..aa.",
    "ddgl..lgdd..aa.",
    "ddgl..lgdd..aa.",
    "ddgllllgdd..aa.",
    ".ddggggdd..aa..",
    ".dddddddd.aa...",
    "...dddd........",
]
func rgb(_ hex: Int) -> NSColor {
    NSColor(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: 1)
}
// Palette années 70 : crème, orange brûlé, moutarde, sarcelle.
let cream = rgb(0xF4E3C1), shadow = rgb(0xD6C096)
let palette: [Character: NSColor] = [
    "d": rgb(0x1F1D24),  // disque
    "g": rgb(0x4A4652),  // sillon
    "l": rgb(0xE76F51),  // étiquette orange
    "a": rgb(0xE9A23B),  // bras moutarde
]

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext

// Tuile : la forme exacte des icônes macOS (824 px, coins continus), remplie en crème.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
c.addPath(RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: tile).cgPath)
c.clip()
cream.setFill()
tile.fill()

// Trois bandes rétro en bas de la tuile.
c.setShouldAntialias(false)
for (i, color) in [rgb(0x2A9D8F), rgb(0xE9A23B), rgb(0xE76F51)].enumerated() {
    color.setFill()
    NSRect(x: 100, y: 150 + i * 36, width: 824, height: 36).fill()
}

// Disque et bras : 1 pixel du dessin = 50 px, avec une ombre dure décalée.
let p = 50, w = art[0].count, h = art.count
let ox = (size - w * p) / 2 + 10, top = 170
func cell(_ x: Int, _ y: Int, _ d: Int = 0) -> NSRect {
    NSRect(x: ox + x * p + d, y: size - top - (y + 1) * p - d, width: p, height: p)
}
for pass in 0...1 {
    for (y, row) in art.enumerated() {
        for (x, ch) in row.enumerated() where ch != "." {
            if pass == 0 { shadow.setFill(); cell(x, y, p / 3).fill() } else { palette[ch]!.setFill(); cell(x, y).fill() }
        }
    }
}

NSGraphicsContext.current?.flushGraphics()
let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let set = dir.appendingPathComponent("build/AppIcon.iconset")
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
let master = set.appendingPathComponent("icon_512x512@2x.png")
try! rep.representation(using: .png, properties: [:])!.write(to: master)

func run(_ tool: String, _ args: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: tool)
    task.arguments = args
    task.standardOutput = FileHandle.nullDevice
    try! task.run()
    task.waitUntilExit()
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512)] {
    run("/usr/bin/sips", ["-z", "\(px)", "\(px)", master.path, "--out", set.appendingPathComponent("icon_\(name).png").path])
}
run("/usr/bin/iconutil", ["-c", "icns", set.path, "-o", dir.appendingPathComponent("AppIcon.icns").path])
print("OK : AppIcon.icns")
