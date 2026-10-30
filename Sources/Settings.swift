import AppKit
import ServiceManagement

final class Settings: NSObject {
    var onChange: () -> Void = {}
    var onRemovePermissions: () -> Void = {}

    private var window: NSWindow?
    private var switches: [String: NSSwitch] = [:]
    private var permissionViews: [Permission: (allowed: NSView, allow: NSView)] = [:]
    private var removeButton: NSView?
    // Features that need Accessibility: their switch, lock and detail line.
    private var gated: [(sw: NSSwitch, lock: NSView, note: NSTextField, detail: String)] = []

    func show() {
        if window == nil { window = makeWindow() }
        refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless() // activation can be refused; never open behind other windows
    }

    func refresh() {
        guard window != nil else { return }
        for (key, sw) in switches { sw.state = prefs.bool(forKey: key) ? .on : .off }
        for (p, v) in permissionViews {
            v.allowed.isHidden = !p.granted
            v.allow.isHidden = p.granted
        }
        removeButton?.isHidden = !Permission.allCases.contains(where: \.granted)
        // Locked features keep showing the saved choice, so they come back as they were once allowed.
        let locked = !Permission.accessibility.granted
        for g in gated {
            g.sw.isEnabled = !locked
            g.lock.isHidden = !locked
            g.note.stringValue = locked ? "Needs Accessibility" : g.detail
            g.note.textColor = locked ? .systemOrange : .secondaryLabelColor
        }
    }

    private func makeWindow() -> NSWindow {
        func toggle(_ key: String) -> NSSwitch {
            let sw = NSSwitch()
            sw.controlSize = .small
            sw.target = self
            sw.action = #selector(toggled)
            sw.identifier = NSUserInterfaceItemIdentifier(key)
            switches[key] = sw
            return sw
        }
        func gate(_ icon: String, _ title: String, _ detail: String, _ key: String, tint: NSColor) -> NSView {
            let text = note(detail)
            let lock = symbol("lock.fill", size: 12)
            lock.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(requestAccessibility)))
            NSLayoutConstraint.activate([lock.widthAnchor.constraint(equalToConstant: 14), lock.heightAnchor.constraint(equalToConstant: 16)])
            lock.toolTip = "Allow Accessibility to use \(title.lowercased())"
            let sw = toggle(key)
            gated.append((sw, lock, text, detail))
            let accessory = NSStackView()
            accessory.spacing = 6
            accessory.setViews([lock, sw], in: .trailing)
            accessory.widthAnchor.constraint(equalToConstant: 66).isActive = true // the switch stays put when the lock hides
            return featureRow(icon, title, text, accessory, tint: tint)
        }
        func permission(_ p: Permission) -> NSView {
            let allowed = stack([symbol("checkmark.circle.fill", size: 12, color: .systemGreen),
                                 label("Allowed", size: 12, color: .secondaryLabelColor)], vertical: false, spacing: 4)
            let allow = FlatButton("Allow", primary: true, height: 24, target: self, action: #selector(requestPermission))
            allow.identifier = NSUserInterfaceItemIdentifier(p.rawValue)
            allow.widthAnchor.constraint(equalToConstant: 64).isActive = true
            permissionViews[p] = (allowed, allow)
            let status = NSStackView()
            status.setViews([allowed, allow], in: .trailing)
            status.widthAnchor.constraint(equalToConstant: 84).isActive = true // same column whatever the state
            return status
        }
        func group(_ title: String, _ rows: [NSView], footer: NSView? = nil) -> [NSView] {
            let body = stack(Array(rows.map { [$0, divider()] }.joined().dropLast()), spacing: 9)
            stretch(body)
            return [sectionTitle(title), Card(body, inset: 10)] + (footer.map { [$0] } ?? [])
        }

        let login = NSSwitch()
        login.controlSize = .small
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        login.action = #selector(toggleLogin)

        let remove = NSButton(title: "Remove All Permissions…", target: self, action: #selector(removePermissions))
        remove.isBordered = false
        remove.font = .systemFont(ofSize: 12)
        remove.contentTintColor = .systemRed
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = stack([spacer, remove], vertical: false)
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 4)
        removeButton = remove

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let header = stack([icon, stack([label("Floe", size: 17, weight: .semibold),
                                         label("Version \(version)", size: 11, color: .secondaryLabelColor)], spacing: 1)],
                           vertical: false, spacing: 12)

        let root = stack(
            [header] + group("Permissions", [
                featureRow("hand.raised.fill", "Accessibility", note("Required for ⌘Tab, scrolling and windows"), permission(.accessibility), tint: .systemBlue),
                featureRow("rectangle.inset.filled.on.rectangle", "Screen Recording", note("Optional · live window previews in ⌘Tab"), permission(.screenRecording), tint: .systemPurple),
            ], footer: footer) + group("Windows", [
                gate("rectangle.stack.fill", "Window switcher", "⌘Tab with previews and window counts", "switcher", tint: .systemIndigo),
                gate("xmark", "Quit on close", "Quit apps when their last window closes", "quitOnClose", tint: .systemRed),
                gate("arrow.up.left.and.arrow.down.right", "Maximize windows", "Green button fills the screen · ⌥ for full screen", "maximize", tint: .systemGreen),
            ]) + group("Mouse", [
                gate("computermouse.fill", "Invert mouse scrolling", "Wheel mice only, trackpad stays natural", "invertScroll", tint: .systemOrange),
            ]) + group("System", [
                featureRow("cup.and.heat.waves.fill", "Stay awake", note("Keep the display and Mac from sleeping"), toggle("stayAwake"), tint: .systemBrown),
                featureRow("power", "Launch at login", note("Start Floe when you log in"), login, tint: .systemGray),
            ]),
            spacing: 8)
        root.setCustomSpacing(14, after: header)
        root.edgeInsets = NSEdgeInsets(top: 40, left: 16, bottom: 16, right: 16) // clears the traffic lights
        for v in root.arrangedSubviews { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        root.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        w.title = "Floe Settings"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .windowBackgroundColor
        w.contentView = root
        w.center()
        return w
    }

    @objc private func toggled(_ sw: NSSwitch) {
        prefs.set(sw.state == .on, forKey: sw.identifier!.rawValue)
        onChange()
    }

    @objc private func requestAccessibility() { Permission.accessibility.request() }

    @objc private func requestPermission(_ sender: NSButton) {
        Permission(rawValue: sender.identifier!.rawValue)?.request()
    }

    @objc private func removePermissions() {
        let alert = NSAlert()
        alert.messageText = "Remove all permissions?"
        alert.informativeText = "Floe gives up Accessibility and Screen Recording access and quits. Open it again whenever you want to allow them."
        alert.addButton(withTitle: "Remove and Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.onRemovePermissions() }
        }
    }

    @objc private func toggleLogin(_ sw: NSSwitch) {
        do {
            try sw.state == .on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        } catch {
            sw.state = sw.state == .on ? .off : .on
            NSAlert(error: error).runModal()
        }
    }
}
