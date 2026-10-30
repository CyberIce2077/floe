import AppKit

// Small AppKit building blocks shared by the tray panel and Settings, styled after Vorssaint's cards.

final class Card: NSView {
    private let fill: NSColor, border: Bool

    init(_ content: NSView, inset: CGFloat = 12, fill: NSColor = .controlBackgroundColor, radius: CGFloat = 10, border: Bool = true) {
        self.fill = fill
        self.border = border
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        guard inset > 0 else {
            NSLayoutConstraint.activate([content.centerXAnchor.constraint(equalTo: centerXAnchor), content.centerYAnchor.constraint(equalTo: centerYAnchor)])
            return
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = border ? 1 : 0
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

final class FlatButton: NSButton {
    private var primary = false

    convenience init(_ title: String, symbol: String? = nil, primary: Bool = false, height: CGFloat = 32, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.primary = primary
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = height < 30 ? 6 : 8
        font = .systemFont(ofSize: height < 30 ? 12 : 13, weight: .medium)
        if let symbol {
            self.title = " " + title // a little air between icon and label
            setAccessibilityTitle(title)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        contentTintColor = primary ? .white : .labelColor
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        if primary {
            layer?.backgroundColor = NSColor.controlAccentColor.withSystemEffect(isHighlighted ? .pressed : .none).cgColor
            layer?.borderWidth = 0
            return
        }
        layer?.backgroundColor = (isHighlighted ? NSColor.labelColor.withAlphaComponent(0.08) : .controlBackgroundColor).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var isHighlighted: Bool { didSet { needsDisplay = true } }
}

func roundedMask(radius r: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) { rect in
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    return l
}

func symbol(_ name: String, size: CGFloat = 13, color: NSColor = .secondaryLabelColor) -> NSImageView {
    let v = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!)
    v.symbolConfiguration = .init(pointSize: size, weight: .medium)
    v.contentTintColor = color
    return v
}

func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute? = nil) -> NSStackView {
    let s = NSStackView(views: views)
    s.orientation = vertical ? .vertical : .horizontal
    s.spacing = spacing
    s.alignment = align ?? (vertical ? .leading : .centerY)
    return s
}

// Make every arranged view as wide as its vertical stack.
func stretch(_ s: NSStackView) {
    for v in s.arrangedSubviews { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
}

// A hairline that starts after the row icon, like System Settings.
func divider(inset: CGFloat = 34) -> NSView {
    let b = NSBox()
    b.boxType = .separator
    b.translatesAutoresizingMaskIntoConstraints = false
    let v = NSView()
    v.addSubview(b)
    NSLayoutConstraint.activate([
        b.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: inset),
        b.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        b.topAnchor.constraint(equalTo: v.topAnchor),
        b.bottomAnchor.constraint(equalTo: v.bottomAnchor),
    ])
    return v
}

// A white glyph on a colored rounded square.
func iconTile(_ name: String, _ tint: NSColor) -> NSView {
    let img = symbol(name, size: 12, color: .white)
    img.translatesAutoresizingMaskIntoConstraints = false
    let tile = Card(img, inset: 0, fill: tint, radius: 6, border: false)
    NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 24), tile.heightAnchor.constraint(equalToConstant: 24)])
    return tile
}

// Icon, title and detail on the left, a control on the right.
func featureRow(_ icon: String, _ title: String, _ detail: NSTextField, _ accessory: NSView, tint: NSColor = .controlAccentColor) -> NSView {
    let img = iconTile(icon, tint)
    let text = stack([label(title), detail], spacing: 1)
    text.setContentHuggingPriority(.defaultLow, for: .horizontal)
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    accessory.setContentHuggingPriority(.required, for: .horizontal)
    accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = stack([img, text, accessory], vertical: false, spacing: 10)
    row.distribution = .fill
    return row
}

func note(_ s: String) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    l.font = .systemFont(ofSize: 11)
    l.textColor = .secondaryLabelColor
    return l
}

func sectionTitle(_ s: String) -> NSView {
    let l = label(s.uppercased(), size: 11, weight: .semibold, color: .secondaryLabelColor)
    let pad = stack([l])
    pad.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 0, right: 0)
    return pad
}

enum Permission: String, CaseIterable {
    case accessibility, screenRecording

    var granted: Bool { self == .accessibility ? AXIsProcessTrusted() : CGPreflightScreenCaptureAccess() }

    // Clears Floe's own entry before asking. An entry left by another build still looks switched on in
    // System Settings but doesn't apply to this one, and macOS only prompts for apps it has no entry for.
    func request() {
        Permission.reset(self == .accessibility ? "Accessibility" : "ScreenCapture")
        if self == .accessibility {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        } else {
            CGRequestScreenCaptureAccess()
        }
    }

    static func reset(_ service: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", service, Bundle.main.bundleIdentifier!]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
