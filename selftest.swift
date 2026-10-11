import AppKit

// Auto-vérification : PLATINE_SELFTEST=/chemin.png lance l'app, clique au milieu de la barre de
// progression, appuie deux fois sur espace, agrandit la fenêtre, écrit une image de la fenêtre puis quitte.
// Attention : agit sur la vraie lecture en cours (saut à la moitié du morceau, pause d'une seconde).

private func find<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
    (v as? T) ?? v.subviews.lazy.compactMap { find(type, in: $0) }.first
}

private func report(_ label: String) {
    print("selftest \(label): playing=\(model.t.playing == true) pos=\(Int(model.t.position()))/\(Int(model.t.duration))")
}

private var fakeTrack = false  // morceau injecté : ne pas envoyer de vraie commande (macOS ouvrirait Apple Music)

private func pressSpace() {
    guard !fakeTrack else { return }
    let e = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: player.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
        isARepeat: false, keyCode: 49)!
    NSApp.sendEvent(e)
}

func runSelfTestIfRequested() {
    guard let out = ProcessInfo.processInfo.environment["PLATINE_SELFTEST"] else { return }
    setvbuf(stdout, nil, _IONBF, 0)
    let at = { (s: Double, f: @escaping () -> Void) in DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
    at(1) {
        model.hovering = true
        // Rien ne joue : on injecte un faux morceau pour pouvoir vérifier l'affichage.
        if model.t.title == nil {
            fakeTrack = true
            model.feed(Data("{\"payload\":{\"title\":\"Morceau de test\",\"artist\":\"Artiste de test\",\"playing\":false,\"elapsedTimeMicros\":65000000,\"durationMicros\":200000000,\"bundleIdentifier\":\"com.deezer.deezer-desktop\"}}\n".utf8))
        }
    }  // simule le survol : en affichage carré, les commandes sont masquées sinon
    at(2) {
        report("start")
        print("selftest devices: \(model.devices.map(\.name)) current=\(model.devices.first { $0.id == model.output }?.name ?? "?")")
        guard let scrub = find(ScrubView.self, in: host) else { return print("selftest scrub: ignoré (affichage carré, pas de barre)") }
        let p = scrub.convert(NSPoint(x: scrub.bounds.midX, y: scrub.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            player.sendEvent(
                NSEvent.mouseEvent(
                    with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: player.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
    }
    at(4) {
        report("after-scrub-click-50%")
        let onBar = player.isMovable
        // Survol du haut du lecteur (fond) : le déplacement doit être permis ; survol de la barre : bloqué.
        lockDragging(at: NSPoint(x: 8, y: player.frame.height - 8))
        let onTop = player.isMovable
        if let scrub = find(ScrubView.self, in: host) {
            lockDragging(at: scrub.convert(NSPoint(x: scrub.bounds.midX, y: scrub.bounds.midY), to: nil))
        }
        print("selftest déplacement: après clic sur la barre bloqué=\(!onBar) | survol du haut permis=\(onTop) | survol de la barre bloqué=\(!player.isMovable)")
        pressSpace()
    }
    at(5.5) { report("after-space"); pressSpace() }
    let frame = player.frame
    at(6.5) {
        // Tire la poignée très loin dans les deux sens : la largeur doit buter sur les bornes.
        guard let grip = find(GripView.self, in: host) else { return print("selftest FAIL: no GripView") }
        let p = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)
        let drag = { (type: NSEvent.EventType, x: Double) in
            player.sendEvent(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: x, y: p.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: player.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        drag(.leftMouseDown, p.x)
        drag(.leftMouseDragged, p.x + 2000)
        let big = Int(player.frame.width)
        drag(.leftMouseDragged, p.x - 2000)
        let small = Int(player.frame.width)
        drag(.leftMouseDragged, p.x + 20)
        drag(.leftMouseUp, p.x + 20)
        print("selftest grip: max=\(big) min=\(small) attendu=\(Int(widthRange.upperBound))/\(Int(widthRange.lowerBound))")
    }
    at(7) {
        report("after-space-2")
        delegate.toggle()
        let hidden = !player.isVisible
        let before = model.t.playing
        pressSpace()  // lecteur masqué : ne doit rien faire
        print("selftest toggle: hidden=\(hidden) status-item=\(delegate.item.button?.image != nil)")
        print("selftest raccourci: \(defaults.string(forKey: "hotkey") ?? "?") enregistré=\(hotKeyRef != nil && hotKeyStatus == noErr)")
        print("selftest dock: icône=\(NSApp.activationPolicy() == .regular) menu=\(NSApp.mainMenu?.items.first?.submenu?.items.count ?? 0) entrées")
        print("selftest source: \(model.source.map { "\($0.name) (\($0.id))" } ?? "aucune")")
        // La source se retire de macOS (charge vide) : le dernier morceau doit rester affiché, en pause.
        let titleBefore = model.t.title
        model.feed(Data("{\"type\":\"data\",\"diff\":false,\"payload\":{}}\n".utf8))
        print("selftest source retirée: morceau gardé=\(titleBefore != nil && model.t.title == titleBefore) gone=\(model.gone) commandes coupées=\(!model.active)")
        // Volume : aller-retour sur la valeur réelle, sans la laisser modifiée.
        if let v = systemVolume() {
            let target = v > 0.5 ? v - 0.1 : v + 0.1
            setSystemVolume(target)
            let read = systemVolume() ?? -1
            setSystemVolume(v)
            print("selftest volume: \(Int(v * 100)) % -> réglé \(Int(target * 100)) %, lu \(Int((read * 100).rounded())) % -> remis \(Int(((systemVolume() ?? -1) * 100).rounded())) %")
        } else { print("selftest volume: sortie sans volume réglable") }
        print("selftest update: \(model.update.map { "disponible \($0.version) -> \($0.url)" } ?? "aucune")")
        print("selftest cover: macOS=\(Int(model.art?.representations.first?.pixelsWide ?? 0))px hd=\(Int(model.hd?.representations.first?.pixelsWide ?? 0))px")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [before] in
            print("selftest espace-masqué: lecture inchangée=\(model.t.playing == before) clavier-rendu=\(!player.isKeyWindow)")
            delegate.toggle()
            print("selftest toggle: shown-again=\(player.isVisible)")
            // Image sans survol (commandes masquées en affichage carré), puis avec.
            model.hovering = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                snapshot(host, out.replacingOccurrences(of: ".png", with: "-sans-survol.png"))
                model.hovering = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { finish(out, frame) }
            }
        }
    }
}

private func finish(_ out: String, _ frame: NSRect) {
    do {
        snapshot(host, out)
        // Affichage carré : même vérification visuelle, puis retour à l'état d'origine.
        let wasCompact = compact
        defaults.set(!wasCompact, forKey: "compact")
        applySettings()
        let opacity = defaults.double(forKey: "compactOpacity")
        defaults.set(0.5, forKey: "compactOpacity")
        applySettings()
        print("selftest mode \(compact ? "carré" : "complet"): \(Int(player.frame.width))x\(Int(player.frame.height)) alpha=\(player.alphaValue)")
        defaults.set(opacity, forKey: "compactOpacity")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            snapshot(host, out.replacingOccurrences(of: ".png", with: "-2.png"))
            snapshot(settingsHost, out.replacingOccurrences(of: ".png", with: "-settings.png"))
            defaults.set(wasCompact, forKey: "compact")
            applySettings()
            print("selftest retour: alpha=\(player.alphaValue)")
            defaults.set(frame.width, forKey: widthKey)
            player.setFrame(frame, display: false)  // ne pas mémoriser la taille de test
            // Dernière image : barre du bas en mode volume.
            model.volumeOpen = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                snapshot(host, out.replacingOccurrences(of: ".png", with: "-volume.png"))
                NSApp.terminate(nil)
            }
        }
    }
}

private func snapshot(_ view: NSView, _ path: String) {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
