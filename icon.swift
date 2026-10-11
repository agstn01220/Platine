import AppKit

// Génère AppIcon.icns : `swift icon.swift` (à relancer seulement si on change le dessin).
// Même platine en pixel art que l'icône de la barre des menus, en couleurs rétro, sans lissage.

let art = [
    " oooooooooooooo ",
    "o..............o",
    "o..............o",
    "o...dddd....aa.o",
    "o..dddddd...aa.o",
    "o.dddggddd..aa.o",
    "o.ddgllgdd..aa.o",
    "o.ddgllgdd..aa.o",
    "o.dddggddd..aa.o",
    "o..dddddd..aa..o",
    "o...dddd..aa...o",
    "o............rvo",
    "o..............o",
    " oooooooooooooo ",
]
func rgb(_ hex: Int) -> NSColor {
    NSColor(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: 1)
}
// Palette années 70 : sarcelle, crème, orange brûlé, moutarde.
let palette: [Character: NSColor] = [
    "o": rgb(0x3B2A20),  // contour brun
    ".": rgb(0xF4E3C1),  // plateau crème
    "d": rgb(0x1F1D24),  // disque
    "g": rgb(0x4A4652),  // sillon
    "l": rgb(0xE76F51),  // étiquette orange
    "a": rgb(0xE9A23B),  // bras moutarde
    "r": rgb(0xE76F51),  // boutons
    "v": rgb(0x2A9D8F),
]

let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Fond : carré arrondi aux proportions des icônes macOS, sarcelle foncé.
rgb(0x264653).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()

// Platine : 1 pixel du dessin = 40 px, centrée, avec une ombre dure décalée d'un pixel.
NSGraphicsContext.current?.shouldAntialias = false
let p = 40, w = art[0].count, h = art.count
let ox = (size - w * p) / 2, oy = (size - h * p) / 2
func cell(_ x: Int, _ y: Int, _ dx: Int = 0, _ dy: Int = 0) -> NSRect {
    NSRect(x: ox + x * p + dx, y: size - oy - (y + 1) * p - dy, width: p, height: p)
}
for pass in 0...1 {
    for (y, row) in art.enumerated() {
        for (x, ch) in row.enumerated() where ch != " " {
            if pass == 0 { rgb(0x17303A).setFill(); cell(x, y, p / 2, p / 2).fill() } else { palette[ch]!.setFill(); cell(x, y).fill() }
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
