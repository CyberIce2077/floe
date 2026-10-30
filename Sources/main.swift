import AppKit
import IOKit.pwr_mgt

@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> Int32

let prefs = UserDefaults.standard
prefs.register(defaults: ["switcher": true, "quitOnClose": true, "maximize": true, "invertScroll": true, "stayAwake": false])

final class App: NSObject, NSApplicationDelegate {
    private let tray = Tray()
    private let settings = Settings()
    private var awakeID: IOPMAssertionID = 0
    private var permissionTimer: Timer?
    private var granted: [Bool] = []

    func applicationDidFinishLaunching(_: Notification) {
        // One hung app must never freeze us: cap every AX call.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        tray.onSettings = { [weak self] in self?.settings.show() }
        tray.onAwake = { [weak self] on in
            prefs.set(on, forKey: "stayAwake")
            self?.apply()
        }
        settings.onChange = { [weak self] in self?.apply() }
        settings.onRemovePermissions = { [weak self] in self?.removePermissions() }
        _ = Switcher.shared // start tracking app activation order now
        apply()
        // First run (or a lost grant): explain what's needed instead of a bare system prompt.
        if !Permission.accessibility.granted { settings.show() }
    }

    func applicationWillTerminate(_: Notification) {
        nativeSwitcher(true)
    }

    func apply() {
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

        let missing = Permission.allCases.filter { !$0.granted }
        granted = Permission.allCases.map(\.granted)
        tray.update(awake: awake, missing: missing)
        settings.refresh()
        watchPermissions(missing.isEmpty == false || (trusted && !eventTapRunning))
    }

    // While something is missing, pick up grants from System Settings within a second.
    private func watchPermissions(_ on: Bool) {
        guard on else {
            permissionTimer?.invalidate()
            permissionTimer = nil
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            // The event tap can lag the Accessibility grant by a moment, so retry until it runs.
            if Permission.allCases.map(\.granted) != granted || (AXIsProcessTrusted() && !eventTapRunning) { apply() }
        }
    }

    // Revoke every privacy grant for Floe, then quit; the next launch starts from a clean slate.
    private func removePermissions() {
        nativeSwitcher(true) // without Accessibility the tap goes deaf, so hand ⌘Tab back first
        Permission.reset("All")
        NSApp.terminate(nil)
    }

    // ⌘Tab / ⌘⇧Tab belong to the Dock unless we switch its hotkeys off.
    private func nativeSwitcher(_ on: Bool) {
        _ = CGSSetSymbolicHotKeyEnabled(1, on)
        _ = CGSSetSymbolicHotKeyEnabled(2, on)
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
