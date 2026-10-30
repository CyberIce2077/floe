import AppKit
import IOKit.pwr_mgt
import ServiceManagement

@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> Int32

let prefs = UserDefaults.standard
prefs.register(defaults: ["switcher": true, "quitOnClose": true, "maximize": true, "invertScroll": true, "stayAwake": false])

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let awakeItem = NSMenuItem(title: "Stay Awake", action: #selector(toggleAwake), keyEquivalent: "")
    private let cpuItem = NSMenuItem(title: "CPU  –", action: nil, keyEquivalent: "")
    private let gpuItem = NSMenuItem(title: "GPU  –", action: nil, keyEquivalent: "")
    private var tempTimer: Timer?
    private var awakeID: IOPMAssertionID = 0
    private var settings: NSWindow?

    func applicationDidFinishLaunching(_: Notification) {
        // One hung app must never freeze us: cap every AX call.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let menu = NSMenu()
        menu.delegate = self
        menu.items = [
            awakeItem, .separator(), cpuItem, gpuItem, .separator(),
            NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","),
            NSMenuItem(title: "Quit Floe", action: #selector(NSApplication.terminate), keyEquivalent: "q"),
        ]
        item.menu = menu
        _ = Switcher.shared // start tracking app activation order now
        apply()
        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard AXIsProcessTrusted() else { return }
                self?.apply()
                if eventTapRunning { t.invalidate() } // the tap can lag the grant by a moment
            }
        }
    }

    func applicationWillTerminate(_: Notification) {
        nativeSwitcher(true)
    }

    @objc func apply() {
        let trusted = AXIsProcessTrusted()
        if trusted { startEventTap() }
        invertScroll = prefs.bool(forKey: "invertScroll")
        maximizeOn = prefs.bool(forKey: "maximize")
        switcherOn = prefs.bool(forKey: "switcher") && eventTapRunning
        nativeSwitcher(!switcherOn)
        AutoQuit.shared.enabled = prefs.bool(forKey: "quitOnClose") && trusted

        let awake = prefs.bool(forKey: "stayAwake")
        if awake && awakeID == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Floe: Stay Awake" as CFString, &awakeID)
        } else if !awake && awakeID != 0 {
            IOPMAssertionRelease(awakeID)
            awakeID = 0
        }
        awakeItem.state = awake ? .on : .off
        item.button?.image = NSImage(systemSymbolName: awake ? "snowflake.circle.fill" : "snowflake", accessibilityDescription: "Floe")
    }

    // ⌘Tab / ⌘⇧Tab belong to the Dock unless we switch its hotkeys off.
    private func nativeSwitcher(_ on: Bool) {
        _ = CGSSetSymbolicHotKeyEnabled(1, on)
        _ = CGSSetSymbolicHotKeyEnabled(2, on)
    }

    @objc private func toggleAwake() {
        prefs.set(!prefs.bool(forKey: "stayAwake"), forKey: "stayAwake")
        apply()
    }

    // Temperatures are only read while the menu is open.
    func menuWillOpen(_: NSMenu) {
        updateTemps()
        tempTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.updateTemps() }
        RunLoop.main.add(tempTimer!, forMode: .common)
    }

    func menuDidClose(_: NSMenu) {
        tempTimer?.invalidate()
    }

    // Off the main thread so the menu never waits on the SMC.
    private func updateTemps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fmt = { (v: Double?) in v.map { String(format: "%.0f °C", $0) } ?? "–" }
            let cpu = "CPU  \(fmt(Temps.cpu))", gpu = "GPU  \(fmt(Temps.gpu))"
            DispatchQueue.main.async {
                self.cpuItem.title = cpu
                self.gpuItem.title = gpu
            }
        }
    }

    @objc private func openSettings() {
        if settings == nil { settings = makeSettings() }
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
        settings?.orderFrontRegardless() // activation can be refused; never open behind other windows
    }

    private func makeSettings() -> NSWindow {
        func row(_ title: String, _ detail: String, key: String) -> NSView {
            let sw = NSSwitch()
            sw.state = prefs.bool(forKey: key) ? .on : .off
            sw.target = self
            sw.action = #selector(toggled)
            sw.identifier = NSUserInterfaceItemIdentifier(key)
            return line(title, detail, sw)
        }
        func line(_ title: String, _ detail: String, _ control: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            let sub = NSTextField(wrappingLabelWithString: detail)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            let text = NSStackView(views: [label, sub])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2
            let h = NSStackView(views: [text, control])
            h.alignment = .centerY
            h.distribution = .fill
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            control.setContentHuggingPriority(.required, for: .horizontal)
            return h
        }
        let login = NSSwitch()
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        login.action = #selector(toggleLogin)

        let stack = NSStackView(views: [
            row("Window switcher", "⌘Tab with large icons, window counts and previews. ⌘` picks a window, W closes it, Q quits the app, Esc cancels.", key: "switcher"),
            row("Quit on close", "Quit apps when their last window closes.", key: "quitOnClose"),
            row("Maximize windows", "The green button maximizes instead of going full screen. ⌥-click for full screen.", key: "maximize"),
            row("Invert mouse scrolling", "Reverse wheel mice only; the trackpad keeps natural scrolling.", key: "invertScroll"),
            row("Stay awake", "Keep the display and Mac from sleeping.", key: "stayAwake"),
            line("Launch at login", "Start Floe when you log in.", login),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.views.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 10), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        w.title = "Floe Settings"
        w.isReleasedWhenClosed = false
        w.contentView = stack
        w.center()
        return w
    }

    @objc private func toggled(_ sw: NSSwitch) {
        prefs.set(sw.state == .on, forKey: sw.identifier!.rawValue)
        apply()
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

// pkill / logout send SIGTERM; route it through terminate so the native ⌘Tab comes back.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { NSApp.terminate(nil) }
sigterm.resume()

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
