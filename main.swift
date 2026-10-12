import AppKit
import Carbon.HIToolbox
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
    var bundleIdentifier: String?, parentApplicationBundleIdentifier: String?
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

// Volume général de la sortie audio courante (0...1), celui des touches du clavier.
// nil si la sortie n'a pas de volume réglable (HDMI, certaines sorties virtuelles).
let volumeAddress = { audioAddress(AudioObjectPropertySelector(0x766D_7663) /* 'vmvc' */, kAudioDevicePropertyScopeOutput) }
func systemVolume() -> Double? {
    var a = volumeAddress()
    var v = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    let device = defaultOutput()
    guard AudioObjectHasProperty(device, &a), AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr else { return nil }
    return Double(v)
}
func setSystemVolume(_ volume: Double) {
    var a = volumeAddress()
    var v = Float32(min(max(volume, 0), 1))
    AudioObjectSetPropertyData(defaultOutput(), &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
}

// MARK: - Modèle

final class Model: ObservableObject {
    @Published var t = Track()
    @Published var art: NSImage?  // pochette fournie par macOS (souvent 150 px)
    @Published var hd: NSImage?  // pochette 500 px trouvée sur Deezer pour le même morceau
    private var hdKey = ""
    // App qui joue (Chrome, Deezer…). Gardée après l'arrêt de la lecture, pour pouvoir la rouvrir.
    @Published var source: (id: String, url: URL, icon: NSImage, name: String)?
    @Published var update: (version: String, url: URL)?  // version plus récente publiée sur GitHub
    @Published var pos = 0.0
    @Published var devices: [AudioDevice] = []
    @Published var output = AudioDeviceID(0)
    @Published var dragging = false  // déplacement en cours sur la barre de progression
    @Published var hovering = false  // curseur au-dessus du lecteur
    @Published var volume: Double?  // volume général du Mac, nil si la sortie n'est pas réglable
    @Published var volumeOpen = false  // la barre du bas règle le volume au lieu de la position
    @Published var gone = false  // l'app source s'est retirée de macOS : plus rien n'est commandable
    private var stream: Process?
    private var buffer = Data()

    init() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in self?.checkForUpdate() }
        checkForUpdate()
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
            // Certaines apps (Deezer, Chrome) se retirent de macOS dès la pause. On garde alors le dernier
            // morceau affiché, figé en pause, au lieu de vider le lecteur.
            if new.title == nil, t.title != nil {
                t.elapsedTimeMicros = pos * 1e6
                t.timestampEpochMicros = nil
                t.playing = false
                gone = true
                continue
            }
            gone = false
            if new.artworkData != t.artworkData {
                art = new.artworkData.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            }
            t = new
            // Pour un navigateur, c'est un processus auxiliaire qui joue : l'app à ouvrir est son parent.
            if let id = new.parentApplicationBundleIdentifier ?? new.bundleIdentifier, id != source?.id,
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            {
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                source = (id, url, NSWorkspace.shared.icon(forFile: url.path), name)
            }
            loadCover()
            tick()
        }
    }

    // Compare la version installée à la dernière release GitHub (au lancement, puis une fois par jour).
    // Platine ne se met pas à jour toute seule : elle signale seulement qu'une version plus récente existe.
    func checkForUpdate() {
        struct Release: Decodable { var tag_name: String; var html_url: URL }
        let url = URL(string: "https://api.github.com/repos/agstn01220/Platine/releases/latest")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let release = try? JSONDecoder().decode(Release.self, from: data) else { return }
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            guard latest.compare(current, options: .numeric) == .orderedDescending else { return }
            DispatchQueue.main.async { self?.update = (latest, release.html_url) }
        }.resume()
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
        // Suit aussi les changements faits au clavier.
        let v = systemVolume()
        if v != volume { volume = v }
    }

    // Identifiants MRCommand : 2 = lecture/pause, 4 = suivant, 5 = précédent.
    // Sans lecture en cours, macOS envoie la commande à Apple Music et l'ouvre : on n'envoie donc rien.
    var active: Bool { t.title != nil && !gone }
    func send(_ command: Int) {
        guard active else { return }
        try? adapter(["send", "\(command)"]).run()
    }

    // Lecture / pause. Si l'app source s'est retirée de macOS, on ne peut plus la commander :
    // le bouton la ramène au premier plan pour relancer la lecture depuis sa fenêtre.
    func playPause() {
        if gone, let source {
            NSWorkspace.shared.openApplication(at: source.url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            send(2)
        }
    }

    func seek(to seconds: Double) {
        guard active, t.duration > 0 else { return }
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
        // En affichage carré, la barre est posée sur la pochette assombrie : elle est blanche.
        (compact ? NSColor.white.withAlphaComponent(0.35) : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        (compact ? NSColor.white : NSColor.labelColor).setFill()
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
// Trois affichages : complet (pochette, titre, barre), carré (pochette + commandes au survol) et vinyle
// (platine avec le disque qui tourne + commandes au survol).
enum Mode: String { case full, compact, vinyl }
var mode: Mode {
    // Avant la vue vinyle, le choix était un booléen « compact » : on le reprend s'il n'y a pas encore de mode.
    Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? (defaults.bool(forKey: "compact") ? .compact : .full)
}
// Vrai pour les deux vues carrées, dont les commandes blanches sont posées sur l'image.
var compact: Bool { mode != .full }
var baseSize: NSSize {
    switch mode {
    case .full: return NSSize(width: 380, height: 104)
    case .compact: return NSSize(width: 150, height: 150)
    case .vinyl: return NSSize(width: 180, height: 180)
    }
}
// Bornes de largeur du lecteur, appliquées par la poignée, au lancement et au changement d'affichage.
var widthRange: ClosedRange<Double> {
    switch mode {
    case .full: return 323...437
    case .compact: return 100...240
    case .vinyl: return 130...300
    }
}
var widthKey: String { "width.\(mode.rawValue)" }

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
    // Icône dans le Dock (avec le point « app ouverte ») ou app discrète, visible seulement dans la barre des menus.
    NSApp.setActivationPolicy(defaults.bool(forKey: "dock") ? .regular : .accessory)
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

// Raccourcis proposés dans les réglages : la touche P (position physique) avec différents modificateurs.
let hotKeys: [(id: String, label: String, modifiers: Int)] = [
    ("ctrl-opt", "⌃⌥P", controlKey | optionKey),
    ("opt-cmd", "⌥⌘P", optionKey | cmdKey),
    ("ctrl-opt-cmd", "⌃⌥⌘P", controlKey | optionKey | cmdKey),
]
var hotKeyRef: EventHotKeyRef?
var hotKeyStatus: OSStatus = noErr  // résultat du dernier enregistrement, pour l'auto-vérification
func registerHotKey() {
    if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
    hotKeyRef = nil
    guard let key = hotKeys.first(where: { $0.id == defaults.string(forKey: "hotkey") }) else { return }
    hotKeyStatus = RegisterEventHotKey(
        UInt32(kVK_ANSI_P), UInt32(key.modifiers), EventHotKeyID(signature: 0x504C_5454, id: 1),
        GetApplicationEventTarget(), 0, &hotKeyRef)
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
                .disabled(!m.active).opacity(m.active ? 1 : 0.35)
            Button { m.playPause() } label: {
                Image(systemName: m.t.playing == true ? "pause.fill" : "play.fill")
                    .font(.system(size: 18 * s)).frame(width: 22 * s)
            }
            .disabled(!m.active && !m.gone).opacity(m.active || m.gone ? 1 : 0.35)
            .help(m.gone ? "Ouvrir \(m.source?.name ?? "l'app") pour relancer la lecture" : "")
            Button { m.send(4) } label: { Image(systemName: "forward.fill") }
                .disabled(!m.active).opacity(m.active ? 1 : 0.35)
        }
        .font(.system(size: 13 * s))
        .buttonStyle(.plain)
    }
}

// Éléments communs aux deux affichages : poignée et menu du clic droit.
struct PlayerChrome: ViewModifier {
    @ObservedObject var m: Model
    let radius: CGFloat  // rayon des coins du lecteur
    var gripVisible = true

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) { Grip().frame(width: radius, height: radius).opacity(gripVisible ? 1 : 0) }
            .contextMenu {
                if let update = m.update {
                    Button("Mise à jour disponible (\(update.version))…") { NSWorkspace.shared.open(update.url) }
                    Divider()
                }
                Button("Réglages…") { showSettings() }
                Button("Masquer le lecteur") { setPlayerVisible(false) }
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
                        HStack(spacing: 7 * s) {
                            VolumeButton(m: m, size: 11 * s)
                            OutputMenu(m: m, size: 11 * s)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .overlay(alignment: .leading) { SourceButton(m: m, size: 16 * s) }
                    .padding(.vertical, 2 * s)
                BarRow(m: m, spacing: 6 * s, height: 12 * s, remaining: false)
                    .font(.system(size: 10 * s).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10 * s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16 * s))
        .modifier(PlayerChrome(m: m, radius: 16 * s))
    }
}

// Affichages carrés : la pochette seule, ou la platine vinyle. Boutons, barre et poignée n'apparaissent
// qu'au survol.
struct SquareView: View {
    @ObservedObject var m: Model
    let s: CGFloat
    let vinyl: Bool
    var controlsVisible: Bool { m.hovering || m.dragging || m.volumeOpen }

    var body: some View {
        Group { if vinyl { Turntable(m: m) } else { Artwork(m: m, s: s) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                VStack(spacing: 5 * s) {
                    // Titre et artiste, juste au-dessus des boutons.
                    VStack(spacing: 1 * s) {
                        Text(m.t.title ?? "Aucune lecture en cours").font(.system(size: max(8, 10 * s), weight: .semibold))
                        Text(m.t.artist ?? " ").font(.system(size: max(7.5, 9 * s))).opacity(0.85)
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 8 * s)
                    Controls(m: m, s: s * 1.15, spacing: 20)
                    BarRow(m: m, spacing: 4 * s, height: max(7, 8 * s), remaining: true)
                        .font(.system(size: max(7, 8 * s)).monospacedDigit())
                        .padding(.horizontal, 12 * s)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .frame(maxWidth: .infinity)
                .padding(.top, 24 * s).padding(.bottom, 9 * s)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                .opacity(controlsVisible ? 1 : 0)
            }
            .overlay(alignment: .topLeading) {
                SourceButton(m: m, size: 20 * s)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(7 * s)
                    .opacity(controlsVisible ? 1 : 0)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 7 * s) {
                    VolumeButton(m: m, size: 13 * s)
                    OutputMenu(m: m, size: 13 * s)
                }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 2)
                    .padding(9 * s)
                    .opacity(controlsVisible ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.15), value: controlsVisible)
            .clipShape(RoundedRectangle(cornerRadius: 18 * s))
            .help([m.t.title, m.t.artist].compactMap { $0 }.joined(separator: " – "))
            .modifier(PlayerChrome(m: m, radius: 18 * s, gripVisible: controlsVisible))
    }
}

struct RootView: View {
    @ObservedObject var m: Model
    @AppStorage("mode") var modeName = Mode.full.rawValue

    var body: some View {
        GeometryReader { g in
            let s = g.size.width / baseSize.width
            switch Mode(rawValue: modeName) ?? .full {
            case .full: FullView(m: m, s: s)
            case .compact: SquareView(m: m, s: s, vinyl: false)
            case .vinyl: SquareView(m: m, s: s * 180 / 150, vinyl: true)  // mêmes commandes que le carré, à la même échelle
            }
        }
    }
}

// MARK: - Platine vinyle

// Le disque : sillons, étiquette faite de la pochette, trou central. Pas de drawingGroup : il aplatissait
// le disque en une image à la taille de la vue, et la pochette devenait floue une fois tournée.
struct Disc: View {
    let art: NSImage?

    var body: some View {
        GeometryReader { g in
            let d = g.size.width
            ZStack {
                Circle().fill(Color(white: 0.07))
                ForEach(0..<16, id: \.self) { i in
                    Circle().stroke(Color.white.opacity(i % 4 == 0 ? 0.10 : 0.045), lineWidth: max(0.5, d * 0.004))
                        .frame(width: d * (0.53 + 0.029 * Double(i)), height: d * (0.53 + 0.029 * Double(i)))
                }
                Group {
                    if let art {
                        Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        Color(red: 0.91, green: 0.44, blue: 0.32)
                    }
                }
                .frame(width: d * 0.48, height: d * 0.48)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: d * 0.008))
                Circle().fill(Color(white: 0.85)).frame(width: d * 0.035, height: d * 0.035)
            }
            .frame(width: d, height: d)
        }
    }
}

// Le bras de lecture, dessiné pointant vers le bas depuis son pivot, dans un carré de côté w.
struct Tonearm: View {
    let w: CGFloat
    static let pivot = UnitPoint(x: 0.87, y: 0.15)

    var body: some View {
        let px = Self.pivot.x * w, py = Self.pivot.y * w, length = 0.60 * w
        let metal = LinearGradient(colors: [Color(white: 0.92), Color(white: 0.60)], startPoint: .leading, endPoint: .trailing)
        ZStack {
            Capsule().fill(Color(white: 0.22)).frame(width: 0.055 * w, height: 0.11 * w).position(x: px, y: py - 0.05 * w)  // contrepoids
            Capsule().fill(metal).frame(width: 0.022 * w, height: length).position(x: px, y: py + length / 2)  // tube
            RoundedRectangle(cornerRadius: 0.008 * w).fill(Color(white: 0.14))
                .frame(width: 0.05 * w, height: 0.085 * w).position(x: px, y: py + length)  // tête de lecture
        }
        .frame(width: w, height: w)
        .shadow(color: .black.opacity(0.45), radius: 0.012 * w, x: 0.012 * w, y: 0.02 * w)
    }
}

// Platine vintage : socle en noyer, plateau, disque qui tourne pendant la lecture, et bras
// qui se pose au début du morceau puis glisse vers le centre à mesure qu'il avance.
struct Turntable: View {
    @ObservedObject var m: Model

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let playing = m.t.playing == true
            let progress = m.t.duration > 0 ? min(max(m.pos / m.t.duration, 0), 1) : 0
            // Au repos, le bras est écarté du disque ; en lecture il va du premier sillon (12°) au bord de l'étiquette (27°).
            let armAngle = playing ? 12 + 15 * progress : -4
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.47, green: 0.29, blue: 0.16), Color(red: 0.29, green: 0.17, blue: 0.09)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                // Veinage discret du bois.
                VStack(spacing: w * 0.045) {
                    ForEach(0..<16, id: \.self) { i in Color.black.opacity(i % 3 == 0 ? 0.10 : 0.05).frame(height: max(0.5, w * 0.006)) }
                }
                Circle().fill(Color(white: 0.16)).frame(width: 0.86 * w, height: 0.86 * w)  // plateau
                    .position(x: 0.45 * w, y: 0.53 * w)
                // Un vrai 33 tours fait 200° par seconde : trop vif pour un petit widget. Ici 60° par seconde,
                // soit un tour en 6 secondes. L'angle suit la position dans le morceau : le disque s'arrête à
                // la pause et repart du même endroit.
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { context in
                    Disc(art: m.hd ?? m.art).rotationEffect(.degrees(m.t.position(at: context.date) * 60))
                }
                .frame(width: 0.80 * w, height: 0.80 * w)
                // Reflets fixes : la lumière ne tourne pas avec le disque.
                .overlay(
                    AngularGradient(
                        stops: [
                            .init(color: .clear, location: 0), .init(color: .white.opacity(0.16), location: 0.07),
                            .init(color: .clear, location: 0.15), .init(color: .clear, location: 0.50),
                            .init(color: .white.opacity(0.12), location: 0.57), .init(color: .clear, location: 0.65),
                            .init(color: .clear, location: 1),
                        ], center: .center
                    )
                    .clipShape(Circle())
                    .blendMode(.screen)
                    .allowsHitTesting(false)
                )
                .shadow(color: .black.opacity(0.5), radius: 0.02 * w, y: 0.01 * w)
                .position(x: 0.45 * w, y: 0.53 * w)

                Tonearm(w: w)
                    .rotationEffect(.degrees(armAngle), anchor: Tonearm.pivot)
                    .animation(.easeInOut(duration: 0.8), value: playing)
                // Pivot du bras.
                Circle().fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.45)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 0.115 * w, height: 0.115 * w)
                    .overlay(Circle().fill(Color(white: 0.2)).frame(width: 0.045 * w, height: 0.045 * w))
                    .shadow(color: .black.opacity(0.4), radius: 0.01 * w, y: 0.008 * w)
                    .position(x: Tonearm.pivot.x * w, y: Tonearm.pivot.y * w)
            }
        }
    }
}

// Barre du bas : position dans le morceau (temps écoulé, barre, durée ou temps restant) ou, quand le
// bouton volume est enfoncé, volume général du Mac.
struct BarRow: View {
    @ObservedObject var m: Model
    let spacing: CGFloat, height: CGFloat
    let remaining: Bool

    var body: some View {
        HStack(spacing: spacing) {
            if m.volumeOpen, let volume = m.volume {
                Image(systemName: "speaker.fill")
                VolumeBar(m: m).frame(height: height)
                Text("\(Int((volume * 100).rounded())) %")
            } else {
                Text(clock(m.pos))
                Scrubber(m: m).frame(height: height)
                Text(remaining ? "-" + clock(max(m.t.duration - m.pos, 0)) : clock(m.t.duration))
            }
        }
    }
}

struct VolumeBar: NSViewRepresentable {
    @ObservedObject var m: Model

    func makeNSView(context: Context) -> ScrubView {
        let v = ScrubView()
        v.onDrag = { [m] f in m.volume = f; setSystemVolume(f) }
        v.onEnd = { [m] f in m.volume = f; setSystemVolume(f) }
        return v
    }
    func updateNSView(_ v: ScrubView, context: Context) { v.fraction = m.volume ?? 0 }
}

// Bouton volume : bascule la barre du bas entre position et volume.
struct VolumeButton: View {
    @ObservedObject var m: Model
    let size: CGFloat

    var body: some View {
        if let volume = m.volume {
            Button { m.volumeOpen.toggle() } label: {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: size))
                    .opacity(m.volumeOpen ? 1 : 0.75)
            }
            .buttonStyle(.plain)
            .help("Volume du Mac")
        }
    }
}

// Bouton à l'icône de l'app qui joue : la fait passer au premier plan.
struct SourceButton: View {
    @ObservedObject var m: Model
    let size: CGFloat

    var body: some View {
        if let source = m.source {
            Button {
                NSWorkspace.shared.openApplication(at: source.url, configuration: NSWorkspace.OpenConfiguration())
            } label: {
                Image(nsImage: source.icon).resizable().interpolation(.high).frame(width: size, height: size)
            }
            .buttonStyle(.plain)
            .help("Ouvrir \(source.name)")
        }
    }
}

// Bouton haut-parleur : ouvre la liste des sorties audio.
struct OutputMenu: View {
    @ObservedObject var m: Model
    let size: CGFloat

    var body: some View {
        Menu {
            OutputPicker(m: m).pickerStyle(.inline)
        } label: {
            Image(systemName: "hifispeaker.fill").font(.system(size: size))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Sortie audio")
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
    @AppStorage("mode") var modeName = Mode.full.rawValue
    @AppStorage("floating") var floating = true
    @AppStorage("compactOpacity") var compactOpacity = 1.0
    @AppStorage("hdCovers") var hdCovers = true
    @AppStorage("hotkey") var hotkey = "ctrl-opt"
    @AppStorage("dock") var dock = true
    @State var login = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Picker("Affichage", selection: $modeName) {
                Text("Complet : pochette, titre, progression").tag(Mode.full.rawValue)
                Text("Carré : pochette, commandes au survol").tag(Mode.compact.rawValue)
                Text("Vinyle : platine avec le disque qui tourne").tag(Mode.vinyl.rawValue)
            }
            .pickerStyle(.radioGroup)
            Slider(value: $compactOpacity, in: 0.3...1) { Text("Opacité (carré, vinyle)") }
                .disabled(modeName == Mode.full.rawValue)
            OutputPicker(m: m)
            Picker("Afficher / masquer", selection: $hotkey) {
                Text("Aucun").tag("none")
                ForEach(hotKeys, id: \.id) { Text($0.label).tag($0.id) }
            }
            Toggle("Pochettes haute définition (via deezer.com)", isOn: $hdCovers)
            Toggle("Toujours au premier plan", isOn: $floating)
            Toggle("Icône dans le Dock", isOn: $dock)
            Toggle("Lancer à l'ouverture de session", isOn: $login)
            Text("Platine \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.footnote).foregroundStyle(.secondary)
            if let update = m.update {
                Link("Mise à jour disponible : Platine \(update.version)", destination: update.url).font(.footnote)
            }
        }
        .onChange(of: modeName) { _ in applySettings() }
        .onChange(of: floating) { _ in applySettings() }
        .onChange(of: dock) { _ in applySettings() }
        .onChange(of: hotkey) { _ in registerHotKey() }
        .onChange(of: compactOpacity) { _ in applySettings() }
        .onChange(of: login) { on in
            do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch {
                NSAlert(error: error).runModal()
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

// Un panneau sans bordure refuse le clavier par défaut : il le faut pour la barre d'espace.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { lockDragging(at: event.locationInWindow) }
        super.sendEvent(event)
    }
}

// La fenêtre se déplace en la tirant par le fond, sauf depuis la barre de progression, la poignée et, en
// affichage carré, toute la zone basse où se trouvent les commandes. C'est décidé dès le survol : le faire
// au moment du clic arrivait trop tard, la fenêtre partait quand même avec la barre.
func lockDragging(at point: NSPoint) {
    let hit = host.hitTest(point)
    let locked = hit is ScrubView || hit is GripView || (compact && point.y < player.frame.height * 0.48)
    player.isMovableByWindowBackground = !locked
    player.isMovable = !locked
}

// Suit l'entrée et la sortie du curseur, même quand Platine n'est pas l'app active.
final class HoverTracker: NSResponder {
    override func mouseEntered(with event: NSEvent) { model.hovering = true; lockDragging(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { lockDragging(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { model.hovering = false; model.volumeOpen = false }
}

// MARK: - Lancement

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
defaults.set(mode.rawValue, forKey: "mode")  // fige le mode (reprise de l'ancien réglage « compact »)
defaults.register(defaults: ["floating": true, "compactOpacity": 1.0, "hdCovers": true, "hotkey": "ctrl-opt", "dock": true])
let model = Model()
let host = NSHostingView(rootView: RootView(m: model))
let hoverTracker = HoverTracker()
host.addTrackingArea(
    NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: hoverTracker, userInfo: nil))
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
// Affiche ou masque le lecteur, et s'en souvient : masqué, il le reste au prochain lancement.
func setPlayerVisible(_ visible: Bool) {
    defaults.set(!visible, forKey: "hidden")
    if visible { player.orderFrontRegardless() } else { player.orderOut(nil) }
}
setPlayerVisible(!defaults.bool(forKey: "hidden"))

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
    // Lecteur masqué : il ne doit plus rien commander, même s'il a gardé le clavier.
    guard e.window === player, player.isVisible else { return e }
    let shift = e.modifierFlags.contains(.shift)
    switch e.keyCode {
    case 49: model.playPause()
    case 123: shift ? model.send(5) : model.seek(to: model.t.position() - 10)
    case 124: shift ? model.send(4) : model.seek(to: model.t.position() + 10)
    default: return e
    }
    return nil
}

// Icône de la barre des menus : une platine vinyle vue de dessus, en pixel art (1 pixel = 1 pt).
// L'image fait exactement la taille du dessin, pour que macOS l'espace comme les autres icônes.
let statusIcon: NSImage = {
    let rows = [
        ".##############.",
        "#..............#",
        "#..............#",
        "#...####....##.#",
        "#..######...##.#",
        "#.########..##.#",
        "#.###..###..##.#",
        "#.###..###..##.#",
        "#.########..##.#",
        "#..######..##..#",
        "#...####..##...#",
        "#..............#",
        "#..............#",
        ".##############.",
    ]
    let image = NSImage(size: NSSize(width: rows[0].count, height: rows.count), flipped: true) { _ in
        NSGraphicsContext.current?.shouldAntialias = false
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() where pixel == "#" { NSRect(x: x, y: y, width: 1, height: 1).fill() }
        }
        return true
    }
    image.isTemplate = true  // macOS l'adapte à la barre claire ou sombre
    image.accessibilityDescription = "Platine"
    return image
}()

// Icône de la barre des menus : clic = afficher/masquer le lecteur, clic droit = menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()
        item.button?.image = statusIcon
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func toggle() { setPlayerVisible(!player.isVisible) }
    @objc func settings() { showSettings() }
    @objc func openUpdate() { if let update = model.update { NSWorkspace.shared.open(update.url) } }

    @objc func clicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return toggle() }
        let menu = NSMenu()
        if let update = model.update {
            menu.addItem(withTitle: "Mise à jour disponible (\(update.version))…", action: #selector(openUpdate), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: player.isVisible ? "Masquer le lecteur" : "Afficher le lecteur", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Réglages…", action: #selector(settings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // Clic sur l'icône du Dock (ou relance de l'app déjà ouverte) : ouvre les réglages.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return false
    }
}
let delegate = AppDelegate()
app.delegate = delegate

// Menu de l'app, visible quand Platine est au premier plan (icône du Dock activée).
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Réglages…", action: #selector(AppDelegate.settings), keyEquivalent: ",").target = delegate
appMenu.addItem(withTitle: "Afficher / masquer le lecteur", action: #selector(AppDelegate.toggle), keyEquivalent: "").target = delegate
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quitter Platine", action: #selector(NSApplication.terminate), keyEquivalent: "q")
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)
app.mainMenu = mainMenu

// Raccourci clavier global (actif dans toutes les apps) pour afficher / masquer le lecteur.
// Carbon reste le seul moyen de le faire sans demander l'autorisation Accessibilité.
InstallEventHandler(
    GetApplicationEventTarget(), { _, _, _ in delegate.toggle(); return noErr }, 1,
    [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))], nil, nil)
registerHotKey()

runSelfTestIfRequested()
app.run()
