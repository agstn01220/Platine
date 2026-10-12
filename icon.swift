import AppKit
import SwiftUI

// Génère AppIcon.icns : `swift icon.swift` (à relancer seulement si on change le dessin).
// Le logo en pixel art de la barre des menus, sur une tuile de couleur. Pour changer de teinte, il suffit
// de modifier les trois couleurs ci-dessous.

func rgb(_ hex: Int) -> NSColor {
    NSColor(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: 1)
}
let background = rgb(0xE9A23B)  // moutarde
let shadow = rgb(0xB5761A)  // ombre dure sous le dessin
let ink = rgb(0x2B2118)  // brun foncé

// Même dessin que `statusIcon` dans main.swift.
let art = [
    ".##############.", "#..............#", "#..............#", "#...####....##.#", "#..######...##.#",
    "#.########..##.#", "#.###..###..##.#", "#.###..###..##.#", "#.########..##.#", "#..######..##..#",
    "#...####..##...#", "#..............#", "#..............#", ".##############.",
]

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext

// Tuile : la forme exacte des icônes macOS (824 px, coins continus).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
c.addPath(RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: tile).cgPath)
c.clip()
background.setFill()
tile.fill()

// Dessin : 1 pixel = 30 px, centré, sans lissage, avec une ombre dure décalée d'un tiers de pixel.
c.setShouldAntialias(false)
let p = 30, ox = (size - art[0].count * p) / 2, oy = (size - art.count * p) / 2
for pass in 0...1 {
    for (y, row) in art.enumerated() {
        for (x, ch) in row.enumerated() where ch == "#" {
            (pass == 0 ? shadow : ink).setFill()
            let d = pass == 0 ? p / 3 : 0
            NSRect(x: ox + x * p + d, y: size - oy - (y + 1) * p - d, width: p, height: p).fill()
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
