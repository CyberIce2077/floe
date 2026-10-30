import AppKit

// Quit an app when its last window closes.
// AX only sees windows on the current Space, so closing the last window here also quits an app
// that still has windows on another Space.
final class AutoQuit {
    static let shared = AutoQuit()
    private var observers: [pid_t: AXObserver] = [:]
    private var tokens: [NSObjectProtocol] = []

    var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            enabled ? start() : stop()
        }
    }

    private func start() {
        NSWorkspace.shared.runningApplications.forEach(watch)
        let nc = NSWorkspace.shared.notificationCenter
        tokens = [
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                // Give the app a moment to bring up its AX interface.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if self?.enabled == true { self?.watch(app) } }
            },
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.unwatch(app.processIdentifier)
            },
        ]
    }

    private func stop() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens = []
        observers.keys.forEach(unwatch)
    }

    private func watch(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, app.bundleIdentifier != "com.apple.finder",
              pid != getpid(), observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, onEvent, &obs) == .success, let obs else { return }
        let el = AXUIElementCreateApplication(pid)
        guard AXObserverAddNotification(obs, el, kAXWindowCreatedNotification as CFString, nil) == .success else { return }
        for w in el.windows { AXObserverAddNotification(obs, w, kAXUIElementDestroyedNotification as CFString, nil) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    private func unwatch(_ pid: pid_t) {
        guard let obs = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }
}

private func onEvent(_ obs: AXObserver, _ el: AXUIElement, _ note: CFString, _: UnsafeMutableRawPointer?) {
    if note as String == kAXWindowCreatedNotification {
        AXObserverAddNotification(obs, el, kAXUIElementDestroyedNotification as CFString, nil)
        return
    }
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    // Wait out apps that swap one window for another (welcome screens, tab tear-offs).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        guard AutoQuit.shared.enabled, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              AXUIElementCreateApplication(pid).windows.isEmpty else { return }
        app.terminate()
    }
}
