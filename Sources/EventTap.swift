import AppKit

// Feature flags, written on main by App.apply(), read on the tap thread.
var invertScroll = false
var switcherOn = false
var maximizeOn = false

private var tap: CFMachPort?
private var switching = false
private var swallowMouseUp = false

// The tap lives on its own thread so a busy main thread can never stall scrolling or typing.
func startEventTap() {
    guard tap == nil else { return }
    let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel, .leftMouseDown, .leftMouseUp]
    let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: mask, callback: handle, userInfo: nil) else { return }
    tap = t
    let thread = Thread {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        CFRunLoopRun()
    }
    thread.qualityOfService = .userInteractive
    thread.start()
}

var eventTapRunning: Bool { tap != nil }

private func handle(_: CGEventTapProxy, type: CGEventType, event: CGEvent, _: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .scrollWheel where invertScroll:
        invert(event)
    case .keyDown, .keyUp:
        if switcherOn && switcherKey(event, down: type == .keyDown) { return nil }
    case .flagsChanged where switching && !event.flags.contains(.maskCommand):
        switching = false
        DispatchQueue.main.async { Switcher.shared.commit() }
    case .leftMouseDown where maximizeOn:
        if greenButtonClicked(event) {
            swallowMouseUp = true
            return nil
        }
    case .leftMouseUp where swallowMouseUp:
        swallowMouseUp = false
        return nil
    default: break
    }
    return Unmanaged.passUnretained(event)
}

// Trackpads and Magic Mouse tag every event with a gesture or momentum phase; wheel mice don't.
private func invert(_ e: CGEvent) {
    guard e.getIntegerValueField(.scrollWheelEventScrollPhase) == 0,
          e.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return }
    let axes: [(CGEventField, CGEventField, CGEventField)] = [
        (.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1),
        (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2),
    ]
    for (line, point, fixed) in axes {
        let l = e.getIntegerValueField(line), p = e.getIntegerValueField(point), f = e.getDoubleValueField(fixed)
        e.setIntegerValueField(line, value: -l)
        e.setIntegerValueField(point, value: -p)
        e.setDoubleValueField(fixed, value: -f)
    }
}

private func switcherKey(_ e: CGEvent, down: Bool) -> Bool {
    let key = e.getIntegerValueField(.keyboardEventKeycode)
    if key == 48 && e.flags.contains(.maskCommand) { // ⌘Tab
        if down {
            let back = e.flags.contains(.maskShift), was = switching
            switching = true
            DispatchQueue.main.async { was ? Switcher.shared.step(back ? -1 : 1) : Switcher.shared.begin(backward: back) }
        }
        return true
    }
    guard switching else { return false }
    let action: () -> Void
    switch key {
    case 53: // Esc
        if down { switching = false }
        action = { Switcher.shared.cancel() }
    case 123: action = { Switcher.shared.step(-1) }      // ←
    case 124: action = { Switcher.shared.step(1) }       // →
    case 50: // ⌘` / ⌘⇧`: windows of the selected app
        let back = e.flags.contains(.maskShift)
        action = { Switcher.shared.stepWindow(back ? -1 : 1) }
    case 12: action = { Switcher.shared.quitSelected() } // Q
    case 13: action = { Switcher.shared.closeWindow() }  // W
    default: return false
    }
    if down { DispatchQueue.main.async(execute: action) }
    return true
}

private let systemWide = AXUIElementCreateSystemWide()

// Green button: maximize to the visible screen instead of a new full-screen Space. ⌥-click keeps the native behavior.
private func greenButtonClicked(_ e: CGEvent) -> Bool {
    guard !e.flags.contains(.maskAlternate) else { return false }
    var el: AXUIElement?
    let p = e.location
    guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &el) == .success, let el,
          el.get(kAXSubroleAttribute) == kAXFullScreenButtonSubrole,
          let win: AXUIElement = el.get(kAXWindowAttribute),
          win.get("AXFullScreen") != true else { return false }
    DispatchQueue.main.async { toggleMaximize(win) }
    return true
}

private var savedFrames: [AXUIElement: CGRect] = [:]

private func toggleMaximize(_ win: AXUIElement) {
    guard let f = win.frame, let primary = NSScreen.screens.first else { return }
    let h = primary.frame.height
    let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: f.midX, y: h - f.midY)) } ?? primary
    let v = screen.visibleFrame
    let target = CGRect(x: v.minX, y: h - v.maxY, width: v.width, height: v.height)
    // Terminals snap to their character grid, hence the loose match.
    let maximized = abs(f.minX - target.minX) + abs(f.minY - target.minY) + abs(f.width - target.width) + abs(f.height - target.height) < 40
    if maximized, let old = savedFrames.removeValue(forKey: win) {
        win.frame = old
    } else if !maximized {
        savedFrames[win] = f
        win.frame = target
    }
}
