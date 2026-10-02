import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Settings window that ends text editing when the user clicks anywhere outside
/// the focused field. SwiftUI on macOS otherwise keeps the field first responder
/// on background clicks, so typed values never commit (and the bars never update)
/// until Return or Tab.
private final class CommitOnClickWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           firstResponder is NSTextView,   // the shared field editor is active
           let content = contentView, let root = content.superview {
            let hit = content.hitTest(root.convert(event.locationInWindow, from: nil))
            // Clicks inside the field editor itself keep editing (caret placement);
            // everything else — empty space, sliders, other fields — commits first.
            if !(hit is NSTextView) { makeFirstResponder(nil) }
        }
        super.sendEvent(event)
    }
}

/// Tracks windows per display via the Accessibility API and drives one DockPanel per screen.
final class DockController: NSObject {
    private let store = OrderStore()
    private let settings = SettingsStore()
    private let interceptor = MaximizeInterceptor()
    private var panels: [DockPanel] = []
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var settingsSub: AnyCancellable?
    private var lastPinnedFingerprint: [String] = []
    private var colorPanelOpen = false
    private var axWarnItem: NSMenuItem?
    private var axWarnSeparator: NSMenuItem?
    private var lastTrusted: Bool?

    func start() {
        store.onChange = { [weak self] in self?.refresh() }
        // Appearance-only path: re-render bars from cached windows, no AX round-trips.
        settingsSub = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                for panel in panels { panel.applySettings(settings.effective(for: panel.displayUUID)) }
                syncInterceptor()
                // Pin-list edits need a full refresh (bar contents change), but slider
                // drags shouldn't trigger AX storms — gate on a pinned fingerprint.
                let fp = pinnedFingerprint()
                if fp != lastPinnedFingerprint {
                    lastPinnedFingerprint = fp
                    refresh()
                }
            }
        lastPinnedFingerprint = pinnedFingerprint()
        interceptor.fillFrame = { [weak self] point in self?.fillFrame(at: point) }
        syncInterceptor()
        setUpStatusItem()
        rebuild()

        let wsnc = NSWorkspace.shared.notificationCenter
        [NSWorkspace.didLaunchApplicationNotification,
         NSWorkspace.didTerminateApplicationNotification,
         NSWorkspace.didActivateApplicationNotification,
         NSWorkspace.activeSpaceDidChangeNotification].forEach { name in
            wsnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        }
        // The window list lags the space-switch animation (entering/leaving full screen),
        // so re-check once it settles instead of waiting for the next 1s poll.
        wsnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() }

        // The shared color panel opens at the primary screen's origin by default;
        // move it to the mouse when it opens (but never while it stays open).
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let panel = note.object as? NSColorPanel, !colorPanelOpen else { return }
            colorPanelOpen = true
            positionColorPanel(panel)
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            if note.object is NSColorPanel { self?.colorPanelOpen = false }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }

        if Debug.cursor {
            // Poll while the mouse is over a bar: force-set arrow independently of event
            // delivery, and log both cursors. Separates "no events" from "set() ignored".
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                let m = NSEvent.mouseLocation
                let inside = panels.enumerated()
                    .filter { $0.element.frame.contains(m) }
                    .map { "panel\($0.offset)=\($0.element.frame)" }
                guard !inside.isEmpty else { return }
                NSCursor.arrow.set()
                Debug.log("poll mouse=\(m) over \(inside.joined(separator: " ")) current=\(Debug.describeCursor(NSCursor.current)) system=\(Debug.describeCursor(NSCursor.currentSystem))")
            }
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "SmartDock")
        let menu = NSMenu()
        let warn = NSMenuItem(title: "Grant Accessibility Access…",
                              action: #selector(openAccessibilityPane), keyEquivalent: "")
        warn.target = self
        let warnSep = NSMenuItem.separator()
        menu.addItem(warn)
        menu.addItem(warnSep)
        axWarnItem = warn
        axWarnSeparator = warnSep

        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SmartDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        updateTrustUI()
    }

    /// Warning icon + menu shortcut while Accessibility trust is missing.
    private func updateTrustUI() {
        let trusted = AXIsProcessTrusted()
        guard trusted != lastTrusted else { return }
        lastTrusted = trusted
        axWarnItem?.isHidden = trusted
        axWarnSeparator?.isHidden = trusted
        statusItem?.button?.image = NSImage(
            systemSymbolName: trusted ? "dock.rectangle" : "exclamationmark.triangle.fill",
            accessibilityDescription: "SmartDock")
    }

    @objc private func openAccessibilityPane() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let win = CommitOnClickWindow(contentRect: .zero,
                                          styleMask: [.titled, .closable, .miniaturizable],
                                          backing: .buffered, defer: false)
            win.title = "SmartDock Settings"
            win.contentView = NSHostingView(rootView: SettingsView(store: settings))
            win.setContentSize(NSSize(width: 680, height: 420))
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Green-button interception

    private func syncInterceptor() {
        settings.interceptZoom ? interceptor.start() : interceptor.stop()
    }

    /// Target frame for "fill screen beside the bar", in CG (AX) coordinates.
    private func fillFrame(at cgPoint: CGPoint) -> CGRect? {
        let screens = NSScreen.screens
        guard let flipY = screens.first?.frame.maxY else { return nil }
        let cocoa = NSPoint(x: cgPoint.x, y: flipY - cgPoint.y)
        guard let idx = screens.firstIndex(where: { NSMouseInRect(cocoa, $0.frame, false) }) else { return nil }
        let screen = screens[idx]
        let s = settings.effective(for: screen.displayUUID)
        let bar = panels.indices.contains(idx) ? panels[idx].frame : nil
        var fill = screen.visibleFrame

        // Windows butt directly against the bar — no gap.
        switch s.position {
        case .bottom:
            let top = bar?.maxY ?? (fill.minY + s.thickness)
            let cut = max(0, top - fill.minY)
            fill.origin.y += cut
            fill.size.height -= cut
        case .left:
            let edge = bar?.maxX ?? (fill.minX + s.thickness)
            let cut = max(0, edge - fill.minX)
            fill.origin.x += cut
            fill.size.width -= cut
        case .right:
            let edge = bar?.minX ?? (fill.maxX - s.thickness)
            let cut = max(0, fill.maxX - edge)
            fill.size.width -= cut
        }
        guard fill.width > 100, fill.height > 100 else { return nil }
        return CGRect(x: fill.minX, y: flipY - fill.maxY, width: fill.width, height: fill.height)
    }

    /// Open the color panel below-right of the cursor, clamped to the mouse's screen.
    private func positionColorPanel(_ panel: NSColorPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - panel.frame.height - 12)
        origin.x = max(vis.minX, min(origin.x, vis.maxX - panel.frame.width))
        origin.y = max(vis.minY, min(origin.y, vis.maxY - panel.frame.height))
        panel.setFrameOrigin(origin)
    }

    // MARK: - Panels

    private func rebuild() {
        panels.forEach { $0.close() }
        panels = NSScreen.screens.map { screen in
            if let id = screen.displayUUID { settings.register(uuid: id, name: screen.localizedName) }
            return DockPanel(screen: screen, store: store)
        }
        let ids = Set(NSScreen.screens.compactMap(\.displayUUID))
        if settings.connected != ids { settings.connected = ids }
        refresh()
    }

    private func refresh() {
        updateTrustUI()   // flips the menu bar warning as soon as access is granted
        let screens = NSScreen.screens
        guard let flipY = screens.first?.frame.maxY else { return }
        guard screens.count == panels.count else { return rebuild() }

        let myPid = ProcessInfo.processInfo.processIdentifier
        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var windowsByScreen: [Int: [WindowInfo]] = [:]
        var allWindows: [WindowInfo] = []
        var titleBands: [CGRect] = []   // pre-filter strips for the zoom interceptor
        var fullscreenAX: [(pid: pid_t, frame: CGRect)] = []   // native full-screen windows (any space)

        for app in regularApps where !app.isHidden && app.processIdentifier != myPid {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            guard let axWindows = attr(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }

            for axWin in axWindows {
                // Some apps (iWork...) report real windows as AXDialog, especially when minimized.
                let subrole = attr(axWin, kAXSubroleAttribute) as? String
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { continue }
                let isMinimized = attr(axWin, kAXMinimizedAttribute) as? Bool == true

                // Minimized windows keep their last frame (or report none) — default them to screen 0.
                var screenIdx = 0
                var cgFrame: CGRect?
                if let f = frame(of: axWin) {
                    cgFrame = f
                    if !isMinimized, f.width < 60 || f.height < 60 { continue }
                    // AX coords are top-left origin; flip to AppKit's bottom-left.
                    let rect = CGRect(x: f.minX, y: flipY - f.maxY, width: f.width, height: f.height)
                    let best = screens.enumerated()
                        .map { ($0.offset, $0.element.frame.intersection(rect)) }
                        .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
                    if let (idx, overlap) = best, !overlap.isEmpty {
                        screenIdx = idx
                    } else if !isMinimized { continue }
                } else if !isMinimized { continue }

                if !isMinimized, let f = cgFrame {
                    titleBands.append(CGRect(x: f.minX, y: f.minY, width: f.width, height: 34))
                    if attr(axWin, "AXFullScreen") as? Bool == true {
                        fullscreenAX.append((app.processIdentifier, f))
                    }
                }
                let title = attr(axWin, kAXTitleAttribute) as? String ?? ""
                let appName = app.localizedName ?? "Unknown"
                let info = WindowInfo(
                    axWindow: axWin,
                    pid: app.processIdentifier,
                    appName: appName,
                    title: title.isEmpty ? appName : title,
                    icon: app.icon ?? NSImage(),
                    isMinimized: isMinimized)
                windowsByScreen[screenIdx, default: []].append(info)
                allWindows.append(info)
            }
        }

        interceptor.trackedBands = titleBands
        store.sync(runningPids: Set(regularApps.map(\.processIdentifier)),
                   windows: allWindows)

        let fullscreen = fullscreenScreens(screens, flipY: flipY, axFullscreen: fullscreenAX,
                                           appPids: Set(regularApps.map(\.processIdentifier)), myPid: myPid)
        for (idx, panel) in panels.enumerated() {
            let eff = settings.effective(for: panel.displayUUID)
            let arranged = store.arrange(windowsByScreen[idx] ?? [])
            panel.update(pinnedBar(arranged, pinned: eff.pinned, apps: regularApps), eff,
                         suppressed: fullscreen.contains(idx))
        }
    }

    /// Indices of screens currently showing a full-screen app. Two signals, both
    /// checked against CGWindowList, which reports only what's actually on screen in
    /// each display's *current* space (AX also returns full-screen windows parked on
    /// other spaces, which must not hide the bar):
    ///  - Native full screen: an on-screen window matching an `AXFullScreen` window's
    ///    frame. Frame matching is needed because when the menu bar is set to stay
    ///    visible in full screen, the window stops below it — it isn't screen-sized.
    ///  - Borderless full screen (games, some players): a window covering the entire
    ///    screen frame. Zoomed/filled windows stop at the menu bar, so they don't count.
    private func fullscreenScreens(_ screens: [NSScreen], flipY: CGFloat,
                                   axFullscreen: [(pid: pid_t, frame: CGRect)],
                                   appPids: Set<pid_t>, myPid: pid_t) -> Set<Int> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let screenRects = screens.map { s in
            CGRect(x: s.frame.minX, y: flipY - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
                && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
        }
        var result: Set<Int> = []
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != myPid, appPids.contains(pid),   // regular apps only — skips overlay utilities
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            let native = axFullscreen.contains { $0.pid == pid && same($0.frame, bounds) }
            for (idx, rect) in screenRects.enumerated() {
                if same(bounds, rect) || (native && rect.contains(CGPoint(x: bounds.midX, y: bounds.midY))) {
                    result.insert(idx)
                }
            }
        }
        return result
    }

    private func pinnedFingerprint() -> [String] {
        settings.defaults.pinned.map(\.bundleID)
            + settings.monitors.sorted { $0.key < $1.key }
                .flatMap { [$0.key] + ($0.value.pinned?.map(\.bundleID) ?? ["∅"]) }
    }

    /// Pinned apps head every bar in pinned order — their live windows when present
    /// on this screen, an icon placeholder otherwise (even when the app is closed).
    private func pinnedBar(_ arranged: [WindowInfo], pinned: [PinnedApp],
                           apps: [NSRunningApplication]) -> [WindowInfo] {
        guard !pinned.isEmpty else { return arranged }
        var head: [WindowInfo] = []
        var tail = arranged
        for (i, p) in pinned.enumerated() {
            let running = apps.first { $0.bundleIdentifier == p.bundleID }
            if let r = running {
                let group = tail.filter { $0.pid == r.processIdentifier }
                if !group.isEmpty {
                    head += group.map { var w = $0; w.isPinned = true; return w }
                    tail.removeAll { $0.pid == r.processIdentifier }
                    continue
                }
            }
            head.append(WindowInfo(axWindow: nil,
                                   pid: running?.processIdentifier ?? pid_t(-(i + 2)),
                                   appName: p.name, title: p.name,
                                   icon: running?.icon ?? p.icon,
                                   isMinimized: false, bundleID: p.bundleID, isPinned: true))
        }
        return head + tail
    }

    // MARK: - AX helpers

    private func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let pos = attr(window, kAXPositionAttribute), AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
              let sz = attr(window, kAXSizeAttribute), AXValueGetValue(sz as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
