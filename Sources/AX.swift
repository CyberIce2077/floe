import AppKit

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

extension AXUIElement {
    func get<T>(_ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attr as CFString, &v) == .success else { return nil }
        return v as? T
    }

    func set(_ attr: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(self, attr as CFString, value)
    }

    var windows: [AXUIElement] { self.get(kAXWindowsAttribute) ?? [] }
    var standardWindows: [AXUIElement] { windows.filter { $0.get(kAXSubroleAttribute) == kAXStandardWindowSubrole } }

    var windowID: CGWindowID {
        var id: CGWindowID = 0
        _ = _AXUIElementGetWindow(self, &id)
        return id
    }

    // AX coordinates: origin at top-left of the primary screen.
    var frame: CGRect? {
        get {
            guard let p: AXValue = get(kAXPositionAttribute), let s: AXValue = get(kAXSizeAttribute) else { return nil }
            var pt = CGPoint.zero, sz = CGSize.zero
            AXValueGetValue(p, .cgPoint, &pt)
            AXValueGetValue(s, .cgSize, &sz)
            return CGRect(origin: pt, size: sz)
        }
        set {
            guard var r = newValue else { return }
            let size = AXValueCreate(.cgSize, &r.size)!, pos = AXValueCreate(.cgPoint, &r.origin)!
            // Size twice: a window can't grow past the screen edge until it has moved.
            set(kAXSizeAttribute, size)
            set(kAXPositionAttribute, pos)
            set(kAXSizeAttribute, size)
        }
    }
}
