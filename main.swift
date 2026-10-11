import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

// Mini player flottant pour tout ce qui joue sur le Mac (Chrome, Deezer, Spotify, Safari...).
// Source : le « À l'écoute » de macOS, lu via mediaremote-adapter (vendor/), lancé par /usr/bin/perl
// parce que MediaRemote est réservé aux binaires Apple depuis macOS 15.4.

// MARK: - Lecture en cours

let res = Bundle.main.resourcePath!
func adapter(_ args: [String]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = ["\(res)/mediaremote-adapter.pl", "\(res)/MediaRemoteAdapter.framework"] + args
    return p
}

struct Track: Decodable {
    var title: String?, artist: String?, album: String?, artworkData: String?
    var playing: Bool?, playbackRate: Double?
    var elapsedTimeMicros: Double?, durationMicros: Double?, timestampEpochMicros: Double?

    var duration: Double { (durationMicros ?? 0) / 1e6 }
    // La position n'est envoyée qu'aux changements : on l'extrapole depuis son horodatage.
    func position(at now: Date = Date()) -> Double {
        let base = (elapsedTimeMicros ?? 0) / 1e6
        guard playing == true, let ts = timestampEpochMicros else { return base }
        let p = base + (now.timeIntervalSince1970 - ts / 1e6) * (playbackRate ?? 1)
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
}
struct Message: Decodable { var payload: Track }

// Réponse de la recherche publique Deezer, utilisée pour les pochettes haute définition.
struct CoverSearch: Decodable {
    struct Artist: Decodable { var name: String }
    struct Album: Decodable { var title: String; var cover_big: String? }
    struct Item: Decodable { var title: String; var artist: Artist; var album: Album }
    var data: [Item]
}
// Vrai si l'un des deux textes contient l'autre (« Silence » ~ « Silence (2008 Edition) »).
func loosely(_ a: String, _ b: String) -> Bool {
    let a = a.lowercased(), b = b.lowercased()
    return !a.isEmpty && !b.isEmpty && (a.contains(b) || b.contains(a))
}

// MARK: - Sorties audio

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
}
let audioSystem = AudioObjectID(kAudioObjectSystemObject)
func audioAddress(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress
{
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
// ponytail: sorties CoreAudio uniquement (haut-parleurs, casques, Bluetooth, HDMI). Les enceintes AirPlay
// non connectées n'y figurent pas ; il faudrait AVRoutePickerView pour les proposer.
func outputDevices() -> [AudioDevice] {
    var a = audioAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(audioSystem, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(audioSystem, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = audioAddress(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var n: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0 else { return nil }
        var nameAddress = audioAddress(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr, let name else { return nil }
        return AudioDevice(id: id, name: name.takeRetainedValue() as String)
    }
}
func defaultOutput() -> AudioDeviceID {
    var a = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(audioSystem, &a, 0, nil, &size, &id)
    return id
}
func setDefaultOutput(_ id: AudioDeviceID) {
    var a = audioAddress(kAudioHardwarePropertyDefaultOutputDevice)
    var id = id
    AudioObjectSetPropertyData(audioSystem, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
}

// MARK: - Modèle

final class Model: ObservableObject {
    @Published var t = Track()
    @Published var art: NSImage?  // pochette fournie par macOS (souvent 150 px)
    @Published var hd: NSImage?  // pochette 500 px trouvée sur Deezer pour le même morceau
    private var hdKey = ""
    @Published var pos = 0.0
    @Published var devices: [AudioDevice] = []
    @Published var output = AudioDeviceID(0)
    var dragging = false
    private var stream: Process?
    private var buffer = Data()

    init() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) {
            [weak self] _ in
            self?.stream?.terminationHandler = nil
            self?.stream?.terminate()
        }
        start()
        tick()
    }

    func start() {
        let p = adapter(["stream", "--no-diff", "--micros", "--debounce=100"])
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            DispatchQueue.main.async { self?.feed(chunk) }
        }
        // Si l'adaptateur meurt, on le relance.
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start() }
        }
        buffer = Data()
        try? p.run()
        stream = p
    }

    func feed(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let new = (try? JSONDecoder().decode(Message.self, from: line))?.payload else { continue }
            if new.artworkData != t.artworkData {
                art = new.artworkData.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            }
            t = new
            loadCover()
            tick()
        }
    }

    // macOS ne transmet qu'une petite pochette : on cherche la même en 500 px sur l'API publique Deezer.
    // Sans résultat sûr (même titre et même artiste), on garde celle de macOS.
    func loadCover() {
        let key = "\(t.artist ?? "")|\(t.title ?? "")|\(t.album ?? "")"
        guard key != hdKey else { return }
        hdKey = key
        hd = nil
        guard UserDefaults.standard.bool(forKey: "hdCovers"), let title = t.title, let artist = t.artist,
            var query = URLComponents(string: "https://api.deezer.com/search")
        else { return }
        query.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)"), URLQueryItem(name: "limit", value: "10")]
        let album = t.album ?? ""
        URLSession.shared.dataTask(with: query.url!) { [weak self] data, _, _ in
            guard let data, let items = try? JSONDecoder().decode(CoverSearch.self, from: data).data else { return }
            let same = items.filter { loosely($0.title, title) && loosely($0.artist.name, artist) }
            let pick = same.first { loosely($0.album.title, album) } ?? same.first
            guard let url = pick?.album.cover_big.flatMap(URL.init(string:)),
                let image = (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
            else { return }
            DispatchQueue.main.async { if self?.hdKey == key { self?.hd = image } }
        }.resume()
    }

    func tick() {
        if !dragging { pos = t.position() }
        let d = outputDevices(), o = defaultOutput()
        if d != devices { devices = d }
        if o != output { output = o }
    }

    // Identifiants MRCommand : 2 = lecture/pause, 4 = suivant, 5 = précédent.
    // Sans lecture en cours, macOS envoie la commande à Apple Music et l'ouvre : on n'envoie donc rien.
    var active: Bool { t.title != nil }
    func send(_ command: Int) {
        guard active else { return }
        try? adapter(["send", "\(command)"]).run()
    }

    func seek(to seconds: Double) {
        guard t.duration > 0 else { return }
        pos = min(max(seconds, 0), t.duration)
        // On applique tout de suite la nouvelle position, sans attendre la confirmation du lecteur.
        t.elapsedTimeMicros = pos * 1e6
        t.timestampEpochMicros = Date().timeIntervalSince1970 * 1e6
        try? adapter(["seek", "\(Int(pos * 1e6))"]).run()
    }
}

// MARK: - Interface

// Barre de progression en AppKit : un Slider SwiftUI laisse la fenêtre se déplacer à sa place
// (isMovableByWindowBackground) et ne suit pas le redimensionnement.
final class ScrubView: NSView {
    var fraction = 0.0 { didSet { needsDisplay = true } }
    var onDrag: (Double) -> Void = { _ in }
    var onEnd: (Double) -> Void = { _ in }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let knob = bounds.height * 0.85, h = max(3, bounds.height * 0.3)
        let track = NSRect(x: knob / 2, y: (bounds.height - h) / 2, width: bounds.width - knob, height: h)
        let x = track.minX + track.width * fraction
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: x - track.minX, height: h), xRadius: h / 2, yRadius: h / 2).fill()
        NSBezierPath(ovalIn: NSRect(x: x - knob / 2, y: (bounds.height - knob) / 2, width: knob, height: knob)).fill()
    }

    private func value(_ e: NSEvent) -> Double {
        let knob = bounds.height * 0.85
        return min(max((convert(e.locationInWindow, from: nil).x - knob / 2) / (bounds.width - knob), 0), 1)
    }
    override func mouseDown(with e: NSEvent) { fraction = value(e); onDrag(fraction) }
    override func mouseDragged(with e: NSEvent) { fraction = value(e); onDrag(fraction) }
    override func mouseUp(with e: NSEvent) { onEnd(value(e)) }
}

struct Scrubber: NSViewRepresentable {
    @ObservedObject var m: Model

    func makeNSView(context: Context) -> ScrubView {
        let v = ScrubView()
        v.onDrag = { [m] f in m.dragging = true; m.pos = f * m.t.duration }
        v.onEnd = { [m] f in m.dragging = false; m.seek(to: f * m.t.duration) }
        return v
    }
    func updateNSView(_ v: ScrubView, context: Context) {
        v.fraction = m.t.duration > 0 ? m.pos / m.t.duration : 0
    }
}

// MARK: - Réglages et taille du lecteur

let defaults = UserDefaults.standard
// Deux affichages : complet (pochette, titre, barre de progression) ou carré (pochette + boutons).
var compact: Bool { defaults.bool(forKey: "compact") }
var baseSize: NSSize { compact ? NSSize(width: 150, height: 150) : NSSize(width: 380, height: 104) }
// Bornes de largeur du lecteur, appliquées par la poignée, au lancement et au changement d'affichage.
var widthRange: ClosedRange<Double> { compact ? 100...240 : 323...437 }
var widthKey: String { compact ? "width.compact" : "width.full" }

// Redimensionne le lecteur dans les bornes ; le coin haut-gauche reste fixe, les proportions aussi.
func resizePlayer(width: Double) {
    let w = min(max(width, widthRange.lowerBound), widthRange.upperBound)
    let h = w * baseSize.height / baseSize.width
    player.setFrame(NSRect(x: player.frame.minX, y: player.frame.maxY - h, width: w, height: h), display: true)
}
// Applique les réglages à la fenêtre : taille mémorisée pour l'affichage courant, premier plan ou non.
func applySettings() {
    let saved = defaults.double(forKey: widthKey)
    resizePlayer(width: saved > 0 ? saved : baseSize.width)
    player.level = defaults.bool(forKey: "floating") ? .floating : .normal
    player.alphaValue = compact ? defaults.double(forKey: "compactOpacity") : 1
}

// Poignée de redimensionnement : un arc qui suit le coin arrondi bas-droit, toujours à l'intérieur du cadre.
// La vue occupe le carré du coin (côté = rayon du coin).
final class GripView: NSView {
    private var offset = 0.0
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        (compact ? NSColor.white.withAlphaComponent(0.85) : NSColor.tertiaryLabelColor).setStroke()
        let p = NSBezierPath()
        // Centre du cercle du coin = coin haut-gauche de la vue.
        p.appendArc(withCenter: NSPoint(x: 0, y: bounds.maxY), radius: bounds.width - 5, startAngle: 290, endAngle: 340)
        p.lineWidth = 2.5
        p.lineCapStyle = .round
        p.stroke()
    }
    override func mouseDown(with e: NSEvent) { offset = player.frame.width - e.locationInWindow.x }
    override func mouseDragged(with e: NSEvent) { resizePlayer(width: e.locationInWindow.x + offset) }
    override func mouseUp(with e: NSEvent) { defaults.set(player.frame.width, forKey: widthKey) }
}
struct Grip: NSViewRepresentable {
    func makeNSView(context: Context) -> GripView { GripView() }
    func updateNSView(_ v: GripView, context: Context) { v.needsDisplay = true }
}

// MARK: - Lecteur

func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

struct Artwork: View {
    @ObservedObject var m: Model
    let s: CGFloat

    var body: some View {
        if let art = m.hd ?? m.art {
            Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "music.note").font(.system(size: 30 * s)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
        }
    }
}

struct Controls: View {
    @ObservedObject var m: Model
    let s: CGFloat
    let spacing: CGFloat

    var body: some View {
        HStack(spacing: spacing * s) {
            Button { m.send(5) } label: { Image(systemName: "backward.fill") }
            Button { m.send(2) } label: {
                Image(systemName: m.t.playing == true ? "pause.fill" : "play.fill")
                    .font(.system(size: 18 * s)).frame(width: 22 * s)
            }
            Button { m.send(4) } label: { Image(systemName: "forward.fill") }
        }
        .font(.system(size: 13 * s))
        .buttonStyle(.plain)
        .disabled(!m.active)
        .opacity(m.active ? 1 : 0.35)
    }
}

// Éléments communs aux deux affichages : poignée et menu du clic droit.
struct PlayerChrome: ViewModifier {
    let radius: CGFloat  // rayon des coins du lecteur

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) { Grip().frame(width: radius, height: radius) }
            .contextMenu {
                Button("Réglages…") { showSettings() }
                Button("Masquer le lecteur") { player.orderOut(nil) }
                Divider()
                Button("Quitter") { NSApp.terminate(nil) }
            }
    }
}

struct FullView: View {
    @ObservedObject var m: Model
    let s: CGFloat  // facteur d'échelle : largeur de la fenêtre / largeur de base

    var body: some View {
        HStack(spacing: 12 * s) {
            Artwork(m: m, s: s)
                .frame(width: 84 * s, height: 84 * s)
                .clipShape(RoundedRectangle(cornerRadius: 10 * s))

            VStack(spacing: 3 * s) {
                Text(m.t.title ?? "Aucune lecture en cours").font(.system(size: 13 * s, weight: .semibold)).lineLimit(1)
                Text(m.t.artist ?? " ").font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(1)
                Controls(m: m, s: s, spacing: 26)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        Menu {
                            OutputPicker(m: m).pickerStyle(.inline)
                        } label: {
                            Image(systemName: "hifispeaker.fill").font(.system(size: 11 * s)).foregroundStyle(.secondary)
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("Sortie audio")
                    }
                    .padding(.vertical, 2 * s)
                HStack(spacing: 6 * s) {
                    Text(clock(m.pos))
                    Scrubber(m: m).frame(height: 12 * s)
                    Text(clock(m.t.duration))
                }
                .font(.system(size: 10 * s).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(10 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16 * s))
        .modifier(PlayerChrome(radius: 16 * s))
    }
}

// Affichage carré : la pochette, avec les trois boutons par-dessus.
struct CompactView: View {
    @ObservedObject var m: Model
    let s: CGFloat

    var body: some View {
        Artwork(m: m, s: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Controls(m: m, s: s * 1.15, spacing: 20)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 22 * s).padding(.bottom, 12 * s)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 18 * s))
            .help([m.t.title, m.t.artist].compactMap { $0 }.joined(separator: " – "))
            .modifier(PlayerChrome(radius: 18 * s))
    }
}

struct RootView: View {
    @ObservedObject var m: Model
    @AppStorage("compact") var compact = false

    var body: some View {
        GeometryReader { g in
            let s = g.size.width / baseSize.width
            if compact { CompactView(m: m, s: s) } else { FullView(m: m, s: s) }
        }
    }
}

struct OutputPicker: View {
    @ObservedObject var m: Model

    var body: some View {
        Picker("Sortie audio", selection: Binding(get: { m.output }, set: { setDefaultOutput($0); m.tick() })) {
            ForEach(m.devices) { Text($0.name).tag($0.id) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var m: Model
    @AppStorage("compact") var compact = false
    @AppStorage("floating") var floating = true
    @AppStorage("compactOpacity") var compactOpacity = 1.0
    @AppStorage("hdCovers") var hdCovers = true
    @State var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Picker("Affichage", selection: $compact) {
                Text("Complet : pochette, titre et barre de progression").tag(false)
                Text("Carré : pochette et boutons").tag(true)
            }
            .pickerStyle(.radioGroup)
            Slider(value: $compactOpacity, in: 0.3...1) { Text("Opacité du carré") }
                .disabled(!compact)
            OutputPicker(m: m)
            Toggle("Pochettes haute définition (recherche le titre sur deezer.com)", isOn: $hdCovers)
            Toggle("Toujours au premier plan", isOn: $floating)
            Toggle("Lancer à l'ouverture de session", isOn: $login)
            Text("Platine \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: compact) { _ in applySettings() }
        .onChange(of: floating) { _ in applySettings() }
        .onChange(of: compactOpacity) { _ in applySettings() }
        .onChange(of: login) { on in
            do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
                NSAlert(error: error).runModal()
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// Un panneau sans bordure refuse le clavier par défaut : il le faut pour la barre d'espace.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Lancement

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
defaults.register(defaults: ["floating": true, "compactOpacity": 1.0, "hdCovers": true])
let model = Model()
let host = NSHostingView(rootView: RootView(m: model))
let player = KeyPanel(
    contentRect: NSRect(origin: .zero, size: baseSize),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
player.contentView = host
player.hidesOnDeactivate = false
// .transient : visible sur tous les bureaux mais masqué dans Mission Control.
player.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
player.isMovableByWindowBackground = true
player.backgroundColor = .clear
player.hasShadow = true
// Pas de .resizable : le redimensionnement natif des bords ignorait les bornes sur cette fenêtre
// sans bordure. Seule la poignée (GripView) redimensionne.
if !player.setFrameUsingName("Player") { player.center() }
applySettings()
player.setFrameAutosaveName("Player")
player.orderFrontRegardless()

let settingsHost = NSHostingView(rootView: SettingsView(m: model))
let settingsWindow = NSWindow(
    contentRect: NSRect(origin: .zero, size: settingsHost.fittingSize),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
settingsWindow.title = "Réglages de Platine"
settingsWindow.contentView = settingsHost
settingsWindow.isReleasedWhenClosed = false
settingsWindow.center()
func showSettings() {
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow.makeKeyAndOrderFront(nil)
}

// Clavier, quand on a cliqué sur le lecteur : espace = lecture/pause, ←/→ = ∓10 s, ⇧←/⇧→ = précédent/suivant.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
    guard e.window === player else { return e }
    let shift = e.modifierFlags.contains(.shift)
    switch e.keyCode {
    case 49: model.send(2)
    case 123: shift ? model.send(5) : model.seek(to: model.t.position() - 10)
    case 124: shift ? model.send(4) : model.seek(to: model.t.position() + 10)
    default: return e
    }
    return nil
}

// Icône de la barre des menus : une platine vinyle en pixel art, grille 12 x 12 dans 18 pt (1 pixel = 1,5 pt).
let statusIcon: NSImage = {
    let rows = [
        ".##########.", "#..........#", "#..####..#.#", "#.######.#.#", "#.##..##.#.#", "#.##..##.#.#",
        "#.######.#.#", "#..####.#..#", "#......#...#", "#..........#", "#..........#", ".##########.",
    ]
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        NSGraphicsContext.current?.shouldAntialias = false
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() where pixel == "#" {
                NSRect(x: Double(x) * 1.5, y: Double(y) * 1.5, width: 1.5, height: 1.5).fill()
            }
        }
        return true
    }
    image.isTemplate = true  // macOS l'adapte à la barre claire ou sombre
    image.accessibilityDescription = "Platine"
    return image
}()

// Icône de la barre des menus : clic = afficher/masquer le lecteur, clic droit = menu.
// Rouvrir l'app (Launchpad, Spotlight, Finder) réaffiche aussi le lecteur.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        item.button?.image = statusIcon
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func toggle() { player.isVisible ? player.orderOut(nil) : player.orderFrontRegardless() }
    @objc func settings() { showSettings() }

    @objc func clicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return toggle() }
        let menu = NSMenu()
        menu.addItem(withTitle: player.isVisible ? "Masquer le lecteur" : "Afficher le lecteur", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Réglages…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        player.orderFrontRegardless()
        return false
    }
}
let delegate = AppDelegate()
app.delegate = delegate

runSelfTestIfRequested()
app.run()
