import AppKit

// The app icon's floe as a menu bar template: the berg above water solid, the hidden part below faint.
let menuBarIcon: NSImage = {
    func shape(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
        for q in pts.dropFirst() { path.line(to: NSPoint(x: q.0, y: q.1)) }
        path.close()
        return path
    }
    let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
        NSColor.black.set()
        shape([(4.6, 9.6), (6.6, 13.2), (9.2, 16.8), (12.2, 17.6), (14.8, 14), (16, 9.6)]).fill()
        // A thin gap is the water surface; the faint body below is the part you don't see.
        NSColor.black.withAlphaComponent(0.4).setFill()
        shape([(3, 8.4), (17.6, 8.4), (19, 5.2), (16.4, 1.6), (10.6, 0.4), (4.6, 1.2), (1.8, 4.8)]).fill()
        NSColor.black.setFill()
        NSRect(x: 0, y: 8.6, width: 2.4, height: 0.8).fill()
        NSRect(x: 18.2, y: 8.6, width: 2.4, height: 0.8).fill()
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Floe"
    return img
}()

// Stay awake's glint, the icon's four-point star in icy blue. It sits on top of the template icon, which keeps
// macOS's own tinting, and twinkles in once when switched on; Core Animation runs that, so nothing ticks afterwards.
private final class Glint: NSView {
    private let star = CAShapeLayer()
    private(set) var isOn = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        wantsLayer = true
        let path = CGMutablePath(), r: CGFloat = 3.4
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4, d = i % 2 == 0 ? r : r * 0.28
            let pt = CGPoint(x: 4 + d * sin(a), y: 4 + d * cos(a))
            i == 0 ? path.move(to: pt) : path.addLine(to: pt)
        }
        path.closeSubpath()
        star.path = path
        star.bounds = bounds
        star.position = CGPoint(x: 4, y: 4)
        star.opacity = 0
        layer?.addSublayer(star)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Deeper blue on a light menu bar, lighter on a dark one, so it reads on either.
    override func viewDidChangeEffectiveAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        star.fillColor = (dark ? NSColor(red: 0.49, green: 0.78, blue: 0.96, alpha: 1)
                               : NSColor(red: 0.18, green: 0.56, blue: 0.85, alpha: 1)).cgColor
        CATransaction.commit()
    }

    func set(_ on: Bool, animated: Bool) {
        guard on != isOn else { return }
        isOn = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        star.opacity = on ? 1 : 0
        CATransaction.commit()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let anim = CAAnimationGroup()
        if on {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0, 1.5, 0.9, 1]
            scale.keyTimes = [0, 0.45, 0.75, 1]
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = -CGFloat.pi / 2
            spin.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.2
            anim.animations = [scale, spin, fade]
            anim.duration = 0.55
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        } else {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 0.3
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            anim.animations = [scale, fade]
            anim.duration = 0.25
            anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        star.add(anim, forKey: "twinkle")
    }
}

// Decimal units, like Finder: one decimal below 10.
private func bytes(_ v: Double) -> (String, String) {
    var v = v, u = 0
    while v >= 999.5 && u < 4 { v /= 1000; u += 1 }
    return (String(format: v < 9.95 && u > 0 ? "%.1f" : "%.0f", v), ["B", "KB", "MB", "GB", "TB"][u])
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// The menu bar popover. A plain panel that only closes on an outside click, Esc or the icon,
// never on focus changes, so it can't flicker shut the way activation-based popovers do.
final class Tray: NSObject {
    var onSettings: () -> Void = {}
    var onAwake: (Bool) -> Void = { _ in }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let glint = Glint()
    private var shown = false
    private let cpu = label("–", size: 22, weight: .bold)
    private let gpu = label("–", size: 22, weight: .bold)
    private let cpuLoad = (bar: NSProgressIndicator(), text: label("–", size: 11, color: .secondaryLabelColor))
    private let gpuLoad = (bar: NSProgressIndicator(), text: label("–", size: 11, color: .secondaryLabelColor))
    private let disk = label("–", size: 22, weight: .bold)
    private let diskUsed = (bar: NSProgressIndicator(), text: label("–", size: 11, color: .secondaryLabelColor))
    private let down = label("–", size: 22, weight: .bold)
    private let up = label("–", size: 11, color: .secondaryLabelColor)
    private let reads = DispatchQueue(label: "floe.stats", qos: .userInitiated)
    private let awake = NSSwitch()
    private let permissionText = note("")
    private var permissionCard: NSView!
    private var monitors: [Any] = []
    private var timer: Timer?

    private lazy var panel: KeyPanel = {
        let p = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let fx = NSVisualEffectView()
        fx.material = .menu
        fx.state = .active
        // A layer corner radius doesn't clip the behind-window blur; a mask image does, and the shadow follows it.
        fx.maskImage = roundedMask(radius: 14)
        let content = makeContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: fx.topAnchor),
            content.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 300),
        ])
        p.contentView = fx
        return p
    }()

    override init() {
        super.init()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: .leftMouseDown) // open on press, like a menu
        guard let button = item.button else { return }
        button.image = menuBarIcon
        glint.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(glint)
        // The star's centre in the 22×18 icon is (19.3, 15); offsets are from the icon's centre, y pointing down.
        NSLayoutConstraint.activate([
            glint.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: 8.3),
            glint.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: -6),
            glint.widthAnchor.constraint(equalToConstant: 8),
            glint.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    func update(awake on: Bool, missing: [Permission]) {
        glint.set(on, animated: shown) // no twinkle for the state Floe starts in
        shown = true
        _ = panel
        awake.state = on ? .on : .off
        permissionCard.isHidden = missing.isEmpty
        permissionText.stringValue = missing.contains(.accessibility)
            ? "Allow Accessibility to turn on ⌘Tab, scrolling and windows."
            : "Allow Screen Recording for window previews."
        if panel.isVisible { place() }
    }

    @objc private func toggle() {
        panel.isVisible ? close() : open()
    }

    private func open() {
        place()
        panel.orderFrontRegardless()
        panel.makeKey()
        item.button?.highlight(true)
        readStats(disk: true)
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.readStats(disk: false) }
        RunLoop.main.add(timer!, forMode: .common)
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, !onIcon else { return }
                close()
            }!,
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
                guard let self else { return e }
                if e.type == .keyDown && e.keyCode == 53 { close(); return nil }
                // Clicks in our other windows (Settings) close the panel too.
                if e.type == .leftMouseDown && e.window !== panel && !onIcon { close() }
                return e
            }!,
        ]
    }

    // A click on the icon is left to toggle(); if a monitor closed the panel first, toggle would reopen it.
    // Checked by position, since the event's window isn't reliably the status button's.
    private var onIcon: Bool {
        item.button?.window?.frame.contains(NSEvent.mouseLocation) ?? false
    }

    private func close() {
        panel.orderOut(nil)
        item.button?.highlight(false)
        timer?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func place() {
        guard let bw = item.button?.window, let screen = bw.screen else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? .zero
        let v = screen.visibleFrame
        let x = min(max(bw.frame.midX - size.width / 2, v.minX + 8), v.maxX - size.width - 8)
        panel.setFrame(NSRect(x: x, y: bw.frame.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    // Off the main thread so the panel never waits on the SMC; one serial queue so reads never overlap.
    // Free space barely moves, so it's only read when the panel opens.
    private func readStats(disk readDisk: Bool) {
        reads.async {
            let ct = Temps.cpu, gt = Temps.gpu, u = Usage.read(), d = readDisk ? Usage.disk : nil
            DispatchQueue.main.async {
                for (field, t) in [(self.cpu, ct), (self.gpu, gt)] {
                    field.stringValue = t.map { String(format: "%.0f °C", $0) } ?? "–"
                }
                for (load, v) in [(self.cpuLoad, u.cpu), (self.gpuLoad, u.gpu)] {
                    load.bar.doubleValue = v ?? 0
                    load.text.stringValue = v.map { String(format: "%.0f%%", $0) } ?? "–"
                }
                if let d {
                    self.show(self.disk, bytes(d.free), " free")
                    self.diskUsed.bar.doubleValue = (1 - d.free / d.total) * 100
                    self.diskUsed.text.stringValue = String(format: "%.0f%%", (1 - d.free / d.total) * 100)
                }
                self.show(self.down, u.down.map(bytes), "/s")
                self.up.stringValue = u.up.map { let (n, unit) = bytes($0); return "\(n) \(unit)/s" } ?? "–"
            }
        }
    }

    // A big number with its unit in small type, so speeds and sizes fit the tile.
    private func show(_ field: NSTextField, _ v: (String, String)?, _ suffix: String) {
        guard let (n, unit) = v else { return field.stringValue = "–" }
        let s = NSMutableAttributedString(string: n, attributes: [.font: field.font!, .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: " " + unit + suffix, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
        field.attributedStringValue = s
    }

    private func makeContent() -> NSView {
        func meter(_ load: (bar: NSProgressIndicator, text: NSTextField)) -> NSView {
            load.bar.isIndeterminate = false
            load.bar.controlSize = .small
            load.bar.maxValue = 100
            load.text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            load.text.alignment = .right
            load.text.widthAnchor.constraint(equalToConstant: 32).isActive = true
            return stack([load.bar, load.text], vertical: false, spacing: 6)
        }
        func tile(_ icon: String, _ name: String, _ value: NSView, _ footer: NSView, fill: Bool = true) -> NSView {
            let head = stack([symbol(icon, size: 11), label(name, size: 12, color: .secondaryLabelColor)], vertical: false, spacing: 4)
            let body = stack([head, value, footer], spacing: 4, align: .centerX)
            body.setCustomSpacing(8, after: value)
            if fill { footer.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
            return Card(body, inset: 10, fill: NSColor.labelColor.withAlphaComponent(0.05), radius: 8, border: false)
        }
        func card(_ title: String, _ tiles: [NSView]) -> NSView {
            let row = stack(tiles, vertical: false, spacing: 8)
            row.distribution = .fillEqually
            let s = stack([label(title, size: 12, weight: .semibold), row], spacing: 10)
            stretch(s)
            return Card(s)
        }
        for v in [cpu, gpu, disk, down] { v.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold) }
        up.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let temps = card("Temperature and usage", [tile("cpu", "CPU", cpu, meter(cpuLoad)), tile("memorychip", "GPU", gpu, meter(gpuLoad))])
        let io = card("Storage and network", [
            tile("internaldrive", "SSD", disk, meter(diskUsed)),
            tile("network", "Network", stack([symbol("arrow.down", size: 12), down], vertical: false, spacing: 3),
                 stack([symbol("arrow.up", size: 9), up], vertical: false, spacing: 3), fill: false),
        ])

        awake.target = self
        awake.action = #selector(awakeChanged)
        awake.controlSize = .small
        let awakeRow = featureRow("cup.and.heat.waves.fill", "Stay awake", note("Display and Mac won't sleep."), awake, tint: .systemBrown)

        let review = FlatButton("Review", primary: true, height: 24, target: self, action: #selector(settings))
        review.widthAnchor.constraint(equalToConstant: 64).isActive = true
        permissionCard = Card(featureRow("exclamationmark.triangle.fill", "Permissions needed", permissionText, review, tint: .systemOrange), inset: 10)

        let buttons = stack([
            FlatButton("Settings", symbol: "gearshape", target: self, action: #selector(settings)),
            FlatButton("Quit", symbol: "power", target: NSApp, action: #selector(NSApplication.terminate)),
        ], vertical: false, spacing: 8)
        buttons.distribution = .fillEqually

        let root = stack([sectionTitle("System"), temps, io, Card(awakeRow, inset: 10), permissionCard, buttons], spacing: 8)
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for v in root.arrangedSubviews { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20).isActive = true }
        return root
    }

    @objc private func awakeChanged() { onAwake(awake.state == .on) }

    @objc private func settings() {
        close()
        onSettings()
    }
}
