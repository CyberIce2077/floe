import AppKit
import ScreenCaptureKit

struct Win {
    let id: CGWindowID
    let title: String
    let onScreen: Bool
    let fullScreen: Bool
    var image: CGImage?
}

final class Switcher {
    static let shared = Switcher()

    private(set) var apps: [NSRunningApplication] = []
    private(set) var sel = 0
    private(set) var wsel = 0
    private var wins: [pid_t: [Win]] = [:]
    private var scWindows: [SCWindow] = []
    private var captured: Set<CGWindowID> = []
    private var axCounts: [pid_t: Int] = [:]
    private var windowPicked = false
    private var active = false
    private var session = 0
    private var mru: [pid_t] = []

    private lazy var view = SwitcherView()
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = view
        return p
    }()

    init() {
        if let front = NSWorkspace.shared.frontmostApplication { mru = [front.processIdentifier] }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            mru.removeAll { $0 == app.processIdentifier }
            mru.insert(app.processIdentifier, at: 0)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.mru.removeAll { $0 == app.processIdentifier }
        }
    }

    var selected: NSRunningApplication? { apps.indices.contains(sel) ? apps[sel] : nil }
    var selectedWindows: [Win] { selected.map { windows($0.processIdentifier) } ?? [] }
    func windows(_ pid: pid_t) -> [Win] { wins[pid] ?? [] }
    // Window list from ScreenCaptureKit covers every Space; AX is the fallback without Screen Recording.
    func count(_ pid: pid_t) -> Int { wins[pid]?.count ?? axCounts[pid] ?? 0 }

    func begin(backward: Bool) {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let byPid = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        apps = mru.compactMap { byPid[$0] } + running.filter { !mru.contains($0.processIdentifier) }
        guard !apps.isEmpty else { return }
        active = true
        session += 1
        sel = apps.count > 1 ? (backward ? apps.count - 1 : 1) : 0
        wsel = 0
        windowPicked = false
        wins = [:]
        axCounts = [:]
        loadCounts()
        loadWindows()
        // A quick ⌘Tab tap switches without flashing the panel.
        let s = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            if active && session == s { show() }
        }
    }

    func step(_ d: Int) {
        guard active else { return begin(backward: d < 0) }
        sel = (sel + d + apps.count) % apps.count
        wsel = 0
        windowPicked = false
        captureSelected()
        refresh()
    }

    func stepWindow(_ d: Int) {
        let n = selectedWindows.count
        guard active, n > 0 else { return }
        wsel = (wsel + d + n) % n
        windowPicked = true
        refresh()
    }

    func select(_ i: Int) {
        sel = i
        wsel = 0
        windowPicked = false
        commit()
    }

    func selectWindow(_ i: Int) {
        wsel = i
        windowPicked = true
        commit()
    }

    func commit() {
        guard active, let app = selected else { return }
        let picked = windowPicked && selectedWindows.indices.contains(wsel) ? selectedWindows[wsel].id : nil
        close()
        if let picked, let win = axWindow(app, picked) {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            win.set(kAXMainAttribute, kCFBooleanTrue)
            activate(app, allWindows: false)
        } else {
            activate(app) // windows on another Space aren't reachable over AX; activating jumps there
        }
    }

    func cancel() { close() }

    func quitSelected() {
        guard active, let app = selected else { return }
        app.terminate()
        apps.remove(at: sel)
        if apps.isEmpty { return close() }
        sel = min(sel, apps.count - 1)
        wsel = 0
        captureSelected()
        refresh()
    }

    func closeWindow() {
        guard active, let app = selected, selectedWindows.indices.contains(wsel),
              let win = axWindow(app, selectedWindows[wsel].id),
              let button: AXUIElement = win.get(kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        wins[app.processIdentifier]?.remove(at: wsel)
        wsel = max(0, min(wsel, selectedWindows.count - 1))
        refresh()
    }

    private func axWindow(_ app: NSRunningApplication, _ id: CGWindowID) -> AXUIElement? {
        AXUIElementCreateApplication(app.processIdentifier).windows.first { $0.windowID == id }
    }

    private func close() {
        active = false
        panel.orderOut(nil)
        // Thumbnails are only worth their memory while the switcher is up; hand it back to the system.
        wins = [:]
        scWindows = []
        captured = []
        malloc_zone_pressure_relief(nil, 0)
    }

    private func activate(_ app: NSRunningApplication, allWindows: Bool = true) {
        if app.isHidden { app.unhide() }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // Like ⌥ on native ⌘Tab: bring back a minimized window if that's all the app has.
        let all = ax.standardWindows
        if !all.isEmpty, all.allSatisfy({ $0.get(kAXMinimizedAttribute) == true }) {
            all[0].set(kAXMinimizedAttribute, kCFBooleanFalse)
        }
        app.activate(options: allWindows ? .activateAllWindows : [])
        // activate() from a background app can be refused (cooperative activation), AX can't.
        ax.set(kAXFrontmostAttribute, kCFBooleanTrue)
    }

    private func loadCounts() {
        let pids = apps.map(\.processIdentifier), s = session
        DispatchQueue.global(qos: .userInteractive).async {
            var result = [Int](repeating: 0, count: pids.count)
            result.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: pids.count) { i in
                    buf[i] = AXUIElementCreateApplication(pids[i]).standardWindows.count
                }
            }
            DispatchQueue.main.async { [self] in
                guard session == s else { return }
                axCounts = Dictionary(uniqueKeysWithValues: zip(pids, result))
                refresh()
            }
        }
    }

    private func loadWindows() {
        guard CGPreflightScreenCaptureAccess() else { return } // previews are opt-in from Settings
        let pids = Set(apps.map(\.processIdentifier)), s = session
        let screens = NSScreen.screens.map(\.frame.size)
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            // Real windows on other Spaces have titles; offscreen helper windows don't.
            // Background tabs are windows too, but they belong to no Space (minimized windows still do).
            let found = content.windows.filter {
                $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 && !($0.title ?? "").isEmpty
                    && pids.contains($0.owningApplication?.processID ?? 0) && hasSpace($0.windowID)
            }
            let ordered = found.filter(\.isOnScreen) + found.filter { !$0.isOnScreen }
            var byPid: [pid_t: [Win]] = [:]
            for w in ordered {
                byPid[w.owningApplication!.processID, default: []].append(
                    Win(id: w.windowID, title: w.title ?? "", onScreen: w.isOnScreen, fullScreen: screens.contains(w.frame.size)))
            }
            let listed = byPid
            await MainActor.run {
                guard self.session == s else { return }
                self.wins = listed
                self.scWindows = ordered
                self.captureSelected()
                self.refresh()
            }
        }
    }

    // Thumbnails are captured only for the app you land on, so a ⌘Tab costs a few captures, not every window.
    private func captureSelected() {
        guard let pid = selected?.processIdentifier else { return }
        let todo = scWindows.filter { $0.owningApplication?.processID == pid && !captured.contains($0.windowID) }
        captured.formUnion(todo.map(\.windowID))
        let s = session
        for w in todo {
            Task {
                let cfg = SCStreamConfiguration()
                let scale = min(2 * thumbSize.width / w.frame.width, 2 * thumbSize.height / w.frame.height, 2)
                cfg.width = Int(w.frame.width * scale)
                cfg.height = Int(w.frame.height * scale)
                cfg.showsCursor = false
                cfg.ignoreShadowsSingleWindow = true
                guard let img = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) else { return }
                let id = w.windowID
                await MainActor.run {
                    guard self.session == s, let i = self.wins[pid]?.firstIndex(where: { $0.id == id }) else { return }
                    self.wins[pid]![i].image = img
                    if pid == self.selected?.processIdentifier { self.refresh() }
                }
            }
        }
    }

    private func show() {
        refresh()
        panel.orderFrontRegardless()
    }

    private func refresh() {
        guard active else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let size = view.update(from: self, maxWidth: v.width * 0.95)
        // Too many apps for the screen: shrink the whole thing rather than wrap.
        let scale = min(1, v.width * 0.95 / size.width)
        let w = size.width * scale, h = size.height * scale
        panel.setFrame(NSRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h), display: false)
        view.bounds = NSRect(origin: .zero, size: size)
        view.needsDisplay = true
    }
}

private let thumbSize = CGSize(width: 194, height: 113)

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>

private func hasSpace(_ id: CGWindowID) -> Bool {
    let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), 7 /* all Spaces */, [id] as CFArray).takeRetainedValue()
    return CFArrayGetCount(spaces) > 0
}

final class SwitcherView: NSView {
    // Metrics in points.
    private let margin: CGFloat = 20, tileW: CGFloat = 100, tileH: CGFloat = 104, tileGap: CGFloat = 14
    private let rowPadX: CGFloat = 8, rowPadY: CGFloat = 4, cardGap: CGFloat = 11
    private let cardPad: CGFloat = 12, headerH: CGFloat = 47, thumbW: CGFloat = 220, thumbH: CGFloat = 161, thumbGap: CGFloat = 10
    private var cardH: CGFloat { cardPad + headerH + thumbH + 19 }
    private let hintW: CGFloat = 300, hintH: CGFloat = 27, hintGap: CGFloat = 9

    private var apps: [NSRunningApplication] = []
    private var counts: [Int] = []
    private var badges: [Badge] = []
    private var sel = 0
    private var wins: [Win] = []
    private var firstWin = 0
    private var wsel = 0
    private var rowRect = CGRect.zero, cardRect = CGRect.zero, hintRect = CGRect.zero
    private var tileRects: [CGRect] = []
    private var thumbRects: [CGRect] = []

    private enum Badge { case none, fullScreen, elsewhere }

    override var isFlipped: Bool { true }

    func update(from s: Switcher, maxWidth: CGFloat) -> CGSize {
        apps = s.apps
        sel = s.sel
        wsel = s.wsel
        counts = apps.map { s.count($0.processIdentifier) }
        badges = apps.map {
            let w = s.windows($0.processIdentifier)
            if w.contains(where: \.fullScreen) { return .fullScreen }
            return !w.isEmpty && !w.contains(where: \.onScreen) ? .elsewhere : .none
        }
        let all = s.selectedWindows
        let fit = max(1, Int((maxWidth - 2 * margin - 2 * cardPad + thumbGap) / (thumbW + thumbGap)))
        firstWin = wsel >= fit ? wsel - fit + 1 : 0
        wins = Array(all.dropFirst(firstWin).prefix(fit))

        let rowW = 2 * rowPadX + CGFloat(apps.count) * tileW + CGFloat(max(0, apps.count - 1)) * tileGap
        let cardW = wins.isEmpty ? 244 : 2 * cardPad + CGFloat(wins.count) * thumbW + CGFloat(wins.count - 1) * thumbGap
        let w = max(rowW, cardW, hintW) + 2 * margin
        let rowY = margin + cardH + cardGap
        rowRect = CGRect(x: (w - rowW) / 2, y: rowY, width: rowW, height: tileH + 2 * rowPadY)
        tileRects = apps.indices.map {
            CGRect(x: rowRect.minX + rowPadX + CGFloat($0) * (tileW + tileGap), y: rowY + rowPadY, width: tileW, height: tileH)
        }
        // The card floats over the selected app, kept within the row.
        let center = tileRects.indices.contains(sel) ? tileRects[sel].midX : w / 2
        let lo = min(rowRect.minX, (w - cardW) / 2), hi = max(rowRect.maxX - cardW, (w - cardW) / 2)
        let shownH = wins.isEmpty ? cardPad + headerH : cardH
        cardRect = CGRect(x: min(max(center - cardW / 2, lo), hi), y: rowY - cardGap - shownH, width: cardW, height: shownH)
        thumbRects = wins.indices.map {
            CGRect(x: cardRect.minX + cardPad + CGFloat($0) * (thumbW + thumbGap), y: cardRect.minY + cardPad + headerH, width: thumbW, height: thumbH)
        }
        hintRect = CGRect(x: (w - hintW) / 2, y: rowRect.maxY + hintGap, width: hintW, height: hintH)
        return CGSize(width: w, height: hintRect.maxY + margin)
    }

    override func draw(_: NSRect) {
        guard apps.indices.contains(sel) else { return }
        card(rowRect, radius: 18)
        for (i, app) in apps.enumerated() { drawTile(app, tileRects[i], selected: i == sel, badge: badges[i]) }
        drawCard(apps[sel], count: counts[sel])
        card(hintRect, radius: hintH / 2)
        drawHint()
    }

    private func drawTile(_ app: NSRunningApplication, _ r: CGRect, selected: Bool, badge: Badge) {
        if selected { highlight(r) }
        let size: CGFloat = selected ? 72 : 64
        let icon = CGRect(x: r.midX - size / 2, y: r.minY + 48 - size / 2, width: size, height: size)
        app.icon?.draw(in: icon)
        let corner = CGPoint(x: icon.maxX - 5, y: icon.minY + 6) // icons carry ~8% transparent padding
        switch badge {
        case .fullScreen:
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)).fill()
        case .elsewhere:
            glyph("macwindow", in: CGRect(x: corner.x - 8, y: corner.y - 8, width: 16, height: 16), fill: .controlAccentColor)
        case .none: break
        }
        let font = selected ? NSFont.systemFont(ofSize: 12, weight: .semibold) : NSFont.systemFont(ofSize: 11)
        text(app.localizedName ?? "", in: CGRect(x: r.minX + 4, y: r.minY + 84, width: r.width - 8, height: 16), font: font,
             color: selected ? .labelColor : .secondaryLabelColor, align: .center)
    }

    private func drawCard(_ app: NSRunningApplication, count: Int) {
        card(cardRect, radius: 18)
        let x = cardRect.minX + cardPad, top = cardRect.minY + cardPad
        app.icon?.draw(in: CGRect(x: x, y: top + 14, width: 18, height: 18))
        let textW = cardRect.width - 2 * cardPad - 56
        let subtitle = wins.indices.contains(wsel - firstWin) ? wins[wsel - firstWin].title : ""
        let nameY = subtitle.isEmpty ? top + 14 : top + 6
        text(app.localizedName ?? "", in: CGRect(x: x + 28, y: nameY, width: textW, height: 18), font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        if !subtitle.isEmpty {
            text(subtitle, in: CGRect(x: x + 28, y: top + 23, width: textW, height: 16), font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        }
        let c = CGRect(x: cardRect.maxX - cardPad - 20, y: top + 13, width: 20, height: 20)
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(ovalIn: c).fill()
        text("\(count)", in: c.offsetBy(dx: 0, dy: 3), font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor, align: .center)

        for (i, (w, r)) in zip(wins, thumbRects).enumerated() {
            if i == wsel - firstWin { highlight(r) }
            let area = CGRect(x: r.minX + 8, y: r.minY + 8, width: r.width - 16, height: 125)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: area, xRadius: 8, yRadius: 8).fill()
            if let img = w.image {
                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                let s = min((area.width - 12) / iw, (area.height - 12) / ih)
                let ir = CGRect(x: area.midX - iw * s / 2, y: area.midY - ih * s / 2, width: iw * s, height: ih * s)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: ir, xRadius: 6, yRadius: 6).addClip()
                NSImage(cgImage: img, size: .zero).draw(in: ir)
                NSGraphicsContext.restoreGraphicsState()
                let state = w.fullScreen ? "arrow.up.left.and.arrow.down.right" : w.onScreen ? nil : "macwindow"
                if let state { glyph(state, in: CGRect(x: ir.minX + 6, y: ir.maxY - 22, width: 16, height: 16), fill: NSColor.black.withAlphaComponent(0.45)) }
            } else {
                app.icon?.draw(in: CGRect(x: area.midX - 24, y: area.midY - 24, width: 48, height: 48))
            }
            text(w.title, in: CGRect(x: r.minX + 8, y: r.minY + 139, width: r.width - 16, height: 16),
                 font: .systemFont(ofSize: 11, weight: .semibold), color: .labelColor, align: .center)
        }
    }

    private func drawHint() {
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let key: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]
        func part(_ label: String, _ keys: String) -> NSAttributedString {
            let s = NSMutableAttributedString(string: label + "  ", attributes: dim)
            s.append(NSAttributedString(string: keys, attributes: key))
            return s
        }
        let left = part("Apps", "⌘Tab"), right = part("Windows", "⌘ `")
        let mid = hintRect.midX, y = hintRect.midY - left.size().height / 2
        left.draw(at: CGPoint(x: mid - 14 - left.size().width, y: y))
        right.draw(at: CGPoint(x: mid + 14, y: y))
        NSColor.separatorColor.setFill()
        CGRect(x: mid - 0.5, y: hintRect.minY + 7, width: 1, height: hintH - 14).fill()
    }

    private func card(_ r: CGRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow.set()
        cardFill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func highlight(_ r: CGRect) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func glyph(_ symbol: String, in r: CGRect, fill: NSColor) {
        fill.setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [.white]))
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        img.draw(in: CGRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
    }

    private func text(_ s: String, in r: CGRect, font: NSFont, color: NSColor, align: NSTextAlignment = .left) {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = .byTruncatingMiddle
        (s as NSString).draw(in: r, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = tileRects.firstIndex(where: { $0.contains(p) }) { Switcher.shared.select(i) }
        else if let i = thumbRects.firstIndex(where: { $0.contains(p) }) { Switcher.shared.selectWindow(firstWin + i) }
    }
}

private let cardFill = NSColor(name: nil) {
    $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 0.16, alpha: 0.97) : NSColor(white: 0.995, alpha: 0.97)
}
