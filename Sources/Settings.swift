import AppKit
import ServiceManagement

final class Settings: NSObject {
    var onChange: () -> Void = {}

    private var window: NSWindow?
    private var switches: [String: NSSwitch] = [:]
    private var permissionViews: [Permission: (allowed: NSView, allow: NSView)] = [:]

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
    }

    private func makeWindow() -> NSWindow {
        func toggle(_ key: String) -> NSSwitch {
            let sw = NSSwitch()
            sw.target = self
            sw.action = #selector(toggled)
            sw.identifier = NSUserInterfaceItemIdentifier(key)
            switches[key] = sw
            return sw
        }
        func permission(_ p: Permission) -> NSView {
            let allowed = stack([symbol("checkmark.circle.fill", size: 13, color: .systemGreen),
                                 label("Allowed", size: 12, color: .secondaryLabelColor)], vertical: false, spacing: 4)
            let allow = FlatButton("Allow…", primary: true, target: self, action: #selector(requestPermission))
            allow.identifier = NSUserInterfaceItemIdentifier(p.rawValue)
            allow.widthAnchor.constraint(equalToConstant: 76).isActive = true
            permissionViews[p] = (allowed, allow)
            return stack([allowed, allow], vertical: false)
        }
        func group(_ title: String, _ rows: [NSView]) -> [NSView] {
            let body = stack(Array(rows.map { [$0, divider()] }.joined().dropLast()), spacing: 10)
            stretch(body)
            return [sectionTitle(title), Card(body)]
        }
        let login = NSSwitch()
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        login.action = #selector(toggleLogin)

        let root = stack(
            group("Permissions", [
                featureRow("accessibility", "Accessibility", note("Needed for ⌘Tab, mouse scrolling, maximize and quit on close."), permission(.accessibility)),
                featureRow("rectangle.dashed.badge.record", "Screen Recording", note("Optional. Shows live window previews in ⌘Tab."), permission(.screenRecording)),
            ]) + group("Windows", [
                featureRow("rectangle.stack", "Window switcher", note("⌘Tab with previews. ⌘` picks a window, W closes it, Q quits the app."), toggle("switcher")),
                featureRow("xmark.square", "Quit on close", note("Quit apps when their last window closes."), toggle("quitOnClose")),
                featureRow("arrow.up.left.and.arrow.down.right", "Maximize windows", note("The green button fills the screen. ⌥-click for full screen."), toggle("maximize")),
            ]) + group("Mouse", [
                featureRow("computermouse", "Invert mouse scrolling", note("Wheel mice only; the trackpad keeps natural scrolling."), toggle("invertScroll")),
            ]) + group("System", [
                featureRow("cup.and.heat.waves", "Stay awake", note("Keep the display and Mac from sleeping."), toggle("stayAwake")),
                featureRow("power", "Launch at login", note("Start Floe when you log in."), login),
            ]),
            spacing: 8)
        root.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        for v in root.arrangedSubviews { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        root.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        w.title = "Floe Settings"
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

    @objc private func requestPermission(_ sender: NSButton) {
        Permission(rawValue: sender.identifier!.rawValue)?.request()
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
