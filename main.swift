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
    var title: String?, artist: String?, artworkData: String?
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
    @Published var art: NSImage?
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
            tick()
        }
    }

    func tick() {
        if !dragging { pos = t.position() }
        let d = outputDevices(), o = defaultOutput()
        if d != devices { devices = d }
        if o != output { output = o }
    }

    // Identifiants MRCommand : 2 = lecture/pause, 4 = suivant, 5 = précédent.
    func send(_ command: Int) { try? adapter(["send", "\(command)"]).run() }

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

// Poignée de redimensionnement (coin bas-droit) : le coin haut-gauche reste fixe, les proportions aussi.
final class GripView: NSView {
    private var offset = 0.0
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        let p = NSBezierPath()
        for k in [0.35, 0.7] {
            p.move(to: NSPoint(x: bounds.maxX * k, y: 1))
            p.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.maxY * (1 - k)))
        }
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        p.stroke()
    }
    override func mouseDown(with e: NSEvent) { offset = (window?.frame.width ?? 0) - e.locationInWindow.x }
    override func mouseDragged(with e: NSEvent) {
        guard let w = window else { return }
        let width = min(max(e.locationInWindow.x + offset, widthRange.lowerBound), widthRange.upperBound)
        let height = width * baseSize.height / baseSize.width
        w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - height, width: width, height: height), display: true)
    }
}
struct Grip: NSViewRepresentable {
    func makeNSView(context: Context) -> GripView { GripView() }
    func updateNSView(_ v: GripView, context: Context) {}
}

func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

let baseSize = NSSize(width: 380, height: 104)
// Bornes de largeur du lecteur, appliquées par la poignée et au lancement.
let widthRange = baseSize.width * 0.85...baseSize.width * 1.15

struct PlayerView: View {
    @ObservedObject var m: Model
    let s: CGFloat  // facteur d'échelle : largeur de la fenêtre / largeur de base

    var body: some View {
        HStack(spacing: 12 * s) {
            Group {
                if let art = m.art {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 30 * s)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                }
            }
            .frame(width: 84 * s, height: 84 * s)
            .clipShape(RoundedRectangle(cornerRadius: 10 * s))

            VStack(spacing: 3 * s) {
                Text(m.t.title ?? "Aucune lecture en cours").font(.system(size: 13 * s, weight: .semibold)).lineLimit(1)
                Text(m.t.artist ?? " ").font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 26 * s) {
                    Button { m.send(5) } label: { Image(systemName: "backward.fill") }
                    Button { m.send(2) } label: {
                        Image(systemName: m.t.playing == true ? "pause.fill" : "play.fill")
                            .font(.system(size: 18 * s)).frame(width: 22 * s)
                    }
                    Button { m.send(4) } label: { Image(systemName: "forward.fill") }
                }
                .font(.system(size: 13 * s))
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    Menu {
                        Picker("Sortie audio", selection: Binding(get: { m.output }, set: { setDefaultOutput($0); m.tick() })) {
                            ForEach(m.devices) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "hifispeaker.fill").font(.system(size: 11 * s)).foregroundStyle(.secondary)
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sortie audio")
                }
                .buttonStyle(.plain)
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
        .overlay(alignment: .bottomTrailing) { Grip().frame(width: 14, height: 14).padding(5) }
        .contextMenu {
            Toggle(
                "Lancer à l'ouverture de session",
                isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
                            NSAlert(error: error).runModal()
                        }
                    }))
            Button("Masquer le lecteur") { player.orderOut(nil) }
            Divider()
            Button("Quitter") { NSApp.terminate(nil) }
        }
    }
}

// Un panneau sans bordure refuse le clavier par défaut : il le faut pour la barre d'espace.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Lancement

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = Model()
let host = NSHostingView(
    rootView: GeometryReader { g in PlayerView(m: model, s: g.size.width / baseSize.width) })
let player = KeyPanel(
    contentRect: NSRect(origin: .zero, size: baseSize),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
player.contentView = host
player.level = .floating
player.hidesOnDeactivate = false
// .transient : visible sur tous les bureaux mais masqué dans Mission Control.
player.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
player.isMovableByWindowBackground = true
player.backgroundColor = .clear
player.hasShadow = true
// Pas de .resizable : le redimensionnement natif des bords ignorait les bornes sur cette fenêtre
// sans bordure. Seule la poignée (GripView) redimensionne.
if !player.setFrameUsingName("Player") { player.center() }
// Une taille mémorisée hors limites (anciennes versions) est ramenée dans les bornes.
let width = min(max(player.frame.width, widthRange.lowerBound), widthRange.upperBound)
player.setContentSize(NSSize(width: width, height: width * baseSize.height / baseSize.width))
player.setFrameAutosaveName("Player")
player.orderFrontRegardless()

// Clavier, quand on a cliqué sur le lecteur : espace = lecture/pause, ←/→ = ∓10 s, ⇧←/⇧→ = précédent/suivant.
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
    let shift = e.modifierFlags.contains(.shift)
    switch e.keyCode {
    case 49: model.send(2)
    case 123: shift ? model.send(5) : model.seek(to: model.t.position() - 10)
    case 124: shift ? model.send(4) : model.seek(to: model.t.position() + 10)
    default: return e
    }
    return nil
}

// Icône de la barre des menus : clic = afficher/masquer le lecteur, clic droit = menu.
// Rouvrir l'app (Launchpad, Spotlight, Finder) réaffiche aussi le lecteur.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    override init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Platine")
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func toggle() { player.isVisible ? player.orderOut(nil) : player.orderFrontRegardless() }

    @objc func toggleLogin() {
        let service = SMAppService.mainApp
        do { try service.status == .enabled ? service.unregister() : service.register() } catch { NSAlert(error: error).runModal() }
    }

    @objc func clicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return toggle() }
        let menu = NSMenu()
        menu.addItem(withTitle: player.isVisible ? "Masquer le lecteur" : "Afficher le lecteur", action: #selector(toggle), keyEquivalent: "").target = self
        let login = menu.addItem(withTitle: "Lancer à l'ouverture de session", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
