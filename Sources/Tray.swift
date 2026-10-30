import AppKit

// The app icon's floe as a menu bar template: the berg above water solid, the hidden part below outlined.
// Stay awake adds the icon's glint.
func menuBarIcon(awake: Bool) -> NSImage {
    func shape(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: pts[0].0, y: pts[0].1))
        for q in pts.dropFirst() { path.line(to: NSPoint(x: q.0, y: q.1)) }
        return path
    }
    let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
        NSColor.black.set()
        let top = shape([(4.6, 9.6), (6.6, 13.2), (9.2, 16.8), (12.2, 17.6), (14.8, 14), (16, 9.6)])
        top.close()
        top.fill()
        // A thin gap is the water surface; the faint body below is the part you don't see.
        let below = shape([(3, 8.4), (17.6, 8.4), (19, 5.2), (16.4, 1.6), (10.6, 0.4), (4.6, 1.2), (1.8, 4.8)])
        below.close()
        NSColor.black.withAlphaComponent(0.4).setFill()
        below.fill()
        NSColor.black.setFill()
        NSRect(x: 0, y: 8.6, width: 2.4, height: 0.8).fill()
        NSRect(x: 18.2, y: 8.6, width: 2.4, height: 0.8).fill()
        if awake {
            let c = NSPoint(x: 19.3, y: 15), r: CGFloat = 2.6
            let star = NSBezierPath()
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4, d = i % 2 == 0 ? r : r * 0.3
                let pt = NSPoint(x: c.x + d * sin(a), y: c.y + d * cos(a))
                i == 0 ? star.move(to: pt) : star.line(to: pt)
            }
            star.close()
            star.fill()
        }
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Floe"
    return img
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
    private let cpu = label("–", size: 22, weight: .bold)
    private let gpu = label("–", size: 22, weight: .bold)
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
    }

    func update(awake on: Bool, missing: [Permission]) {
        item.button?.image = menuBarIcon(awake: on)
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
        readTemps()
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.readTemps() }
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

    // Off the main thread so the panel never waits on the SMC.
    private func readTemps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fmt = { (v: Double?) in v.map { String(format: "%.0f °C", $0) } ?? "–" }
            let c = fmt(Temps.cpu), g = fmt(Temps.gpu)
            DispatchQueue.main.async {
                self.cpu.stringValue = c
                self.gpu.stringValue = g
            }
        }
    }

    private func makeContent() -> NSView {
        func tile(_ icon: String, _ name: String, _ value: NSTextField) -> NSView {
            let head = stack([symbol(icon, size: 11), label(name, size: 12, color: .secondaryLabelColor)], vertical: false, spacing: 4)
            value.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
            return Card(stack([head, value], spacing: 4, align: .centerX), inset: 10,
                        fill: NSColor.labelColor.withAlphaComponent(0.05), radius: 8, border: false)
        }
        let tiles = stack([tile("cpu", "CPU", cpu), tile("memorychip", "GPU", gpu)], vertical: false, spacing: 8)
        tiles.distribution = .fillEqually
        let temps = stack([label("Temperatures", size: 12, weight: .semibold), tiles], spacing: 10)
        stretch(temps)

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

        let root = stack([sectionTitle("System"), Card(temps), Card(awakeRow, inset: 10), permissionCard, buttons], spacing: 8)
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
