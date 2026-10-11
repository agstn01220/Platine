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

private func pressSpace() {
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
    at(4) { report("after-scrub-click-50%"); pressSpace() }
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
        delegate.toggle()
        print("selftest toggle: hidden=\(hidden) shown-again=\(player.isVisible) status-item=\(delegate.item.button?.image != nil)")
        print("selftest cover: macOS=\(Int(model.art?.representations.first?.pixelsWide ?? 0))px hd=\(Int(model.hd?.representations.first?.pixelsWide ?? 0))px")
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
            NSApp.terminate(nil)
        }
    }
}

private func snapshot(_ view: NSView, _ path: String) {
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
