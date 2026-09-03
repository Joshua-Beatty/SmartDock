import AppKit
import ApplicationServices

/// Replaces zoom-button clicks with "fill the screen beside the SmartDock bar".
/// Active CGEventTap (research/green-button/findings.md): consumes the click pair
/// and performs an AX resize instead. Second click restores; ⌥-click passes through.
final class MaximizeInterceptor {
    /// Titlebar bands (CG top-left coords) of tracked windows — zero-AX pre-filter.
    var trackedBands: [CGRect] = []
    /// Maps a click point (CG coords) to the fill frame (CG coords), minus the bar.
    var fillFrame: (CGPoint) -> CGRect? = { _ in nil }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowUp = false
    private var savedFrames: [Int: CGRect] = [:]   // CFHash(window) → pre-fill frame

    func start() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<MaximizeInterceptor>.fromOpaque(refcon!)
                .takeUnretainedValue()
                .handle(type: type, event: event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            NSLog("SmartDock: could not create event tap — check Accessibility permission")
            return
        }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
        swallowUp = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }   // tap health
            return Unmanaged.passUnretained(event)
        case .leftMouseUp where swallowUp:
            swallowUp = false                                          // consume the pair
            return nil
        case .leftMouseDown:
            return handleDown(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let p = event.location   // CG top-left coords, same space as AX
        guard !event.flags.contains(.maskAlternate),                      // ⌥ → native zoom
              trackedBands.contains(where: { $0.contains(p) }) else { return pass }

        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &hit) == .success,
              let el = hit else { return pass }
        AXUIElementSetMessagingTimeout(el, 0.15)
        // Modern macOS reports the green button as AXFullScreenButton; AXZoomButton when zooming.
        guard let subrole = attr(el, kAXSubroleAttribute) as? String,
              subrole == kAXFullScreenButtonSubrole || subrole == kAXZoomButtonSubrole,
              let window = window(for: el),
              let target = fillFrame(p) else { return pass }
        AXUIElementSetMessagingTimeout(window, 0.25)

        let key = Int(bitPattern: CFHash(window))
        if let current = frame(of: window) {
            if let saved = savedFrames[key], roughly(current, target) {
                savedFrames[key] = nil
                set(window, frame: saved)                    // second press → restore
            } else {
                if savedFrames.count > 64 { savedFrames.removeAll() }
                savedFrames[key] = current
                set(window, frame: target)
            }
        } else {
            set(window, frame: target)
        }
        swallowUp = true
        return nil                                           // consume the click
    }

    // MARK: - AX plumbing

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private func window(for element: AXUIElement) -> AXUIElement? {
        if let w = attr(element, kAXWindowAttribute) { return (w as! AXUIElement) }
        var cur = element
        for _ in 0..<8 {   // fallback: walk kAXParent
            guard let parent = attr(cur, kAXParentAttribute) else { return nil }
            let p = parent as! AXUIElement
            if attr(p, kAXRoleAttribute) as? String == kAXWindowRole { return p }
            cur = p
        }
        return nil
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let pos = attr(window, kAXPositionAttribute), AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
              let sz = attr(window, kAXSizeAttribute), AXValueGetValue(sz as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func set(_ window: AXUIElement, frame f: CGRect) {
        var origin = f.origin, size = f.size
        // size → position → size: survives apps that clamp the first set
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
        if let v = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
    }

    private func roughly(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4 &&
        abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
    }
}
