import AppKit
import SwiftUI

/// Forces the arrow cursor while the pointer is over the bar. SmartDock is never the
/// active app, so SwiftUI hover is dead here — this needs an .activeAlways tracking
/// area, which fires regardless of focus. Without it, the resize cursor picked up
/// from an adjacent window edge sticks around over the bar.
private final class CursorSentinel: NSResponder {
    /// Reports the pointer's window location on every move, nil when it leaves.
    var track: ((CGPoint?) -> Void)?
    private var lastLog = Date.distantPast

    private func fire(_ kind: String, _ event: NSEvent) {
        NSCursor.arrow.set()
        track?(event.locationInWindow)
        if Debug.cursor, Date().timeIntervalSince(lastLog) > 0.1 {
            lastLog = Date()
            Debug.log("\(kind) → set(arrow); current=\(Debug.describeCursor(NSCursor.current)) system=\(Debug.describeCursor(NSCursor.currentSystem))")
        }
    }

    override func mouseEntered(with event: NSEvent) { fire("entered", event) }
    override func mouseMoved(with event: NSEvent) { fire("moved", event) }
    override func mouseExited(with event: NSEvent) {
        track?(nil)
        Debug.log("exited")
    }
    override func cursorUpdate(with event: NSEvent) { fire("cursorUpdate", event) }
}

/// Mouse position over the bar (hosting-view coordinates), fed by the always-on
/// tracking area — SwiftUI's own hover tracking never fires for background apps.
final class HoverModel: ObservableObject {
    @Published var point: CGPoint?
    var barSize: CGSize = .zero   // updated alongside point; used for alignment offsets
}

/// A borderless, non-activating bar pinned to the bottom of one screen.
final class DockPanel {
    let displayUUID: String?
    var frame: NSRect { panel.frame }
    private let panel: NSPanel
    private let hosting: NSHostingView<DockView>
    private let screen: NSScreen
    private let store: OrderStore
    private var lastWindows: [WindowInfo]?
    private var lastSettings = BarSettings()
    private let cursorSentinel = CursorSentinel()
    private let hoverModel = HoverModel()

    init(screen: NSScreen, store: OrderStore) {
        self.screen = screen
        self.store = store
        displayUUID = screen.displayUUID
        hosting = NSHostingView(rootView: DockView(windows: [], store: store,
                                                   settings: BarSettings(), hover: HoverModel()))
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // One notch above normal windows: floats over every app window but stays
        // below system UI (screenshot thumbnail, notification banners, palettes).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting
        hosting.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: cursorSentinel, userInfo: nil))
        Debug.log("tracking area installed for screen \(displayUUID ?? "?"), areas=\(hosting.trackingAreas.count)")
        cursorSentinel.track = { [weak self] location in
            guard let self else { return }
            hoverModel.barSize = hosting.bounds.size
            hoverModel.point = location.map { self.hosting.convert($0, from: nil) }
        }
    }

    func update(_ windows: [WindowInfo], _ settings: BarSettings) {
        guard windows != lastWindows || settings != lastSettings else { return }
        lastWindows = windows
        lastSettings = settings
        render()
    }

    /// Cheap appearance-only path — reuses the cached window list.
    func applySettings(_ settings: BarSettings) {
        guard settings != lastSettings else { return }
        lastSettings = settings
        render()
    }

    private func render() {
        let windows = lastWindows ?? []
        hosting.rootView = DockView(windows: windows, store: store, settings: lastSettings, hover: hoverModel)
        guard !windows.isEmpty else { return panel.orderOut(nil) }

        let size = hosting.fittingSize
        let vis = screen.visibleFrame
        let w = min(size.width, screen.frame.width)
        let h = min(size.height, screen.frame.height)
        let full = lastSettings.fullSpan
        let frame: NSRect
        switch lastSettings.position {
        case .bottom:
            frame = full
                ? NSRect(x: screen.frame.minX, y: vis.minY, width: screen.frame.width, height: h)
                : NSRect(x: screen.frame.midX - w / 2, y: vis.minY, width: w, height: h)
        case .left:
            frame = full
                ? NSRect(x: vis.minX, y: vis.minY, width: w, height: vis.height)
                : NSRect(x: vis.minX, y: screen.frame.midY - h / 2, width: w, height: h)
        case .right:
            frame = full
                ? NSRect(x: vis.maxX - w, y: vis.minY, width: w, height: vis.height)
                : NSRect(x: vis.maxX - w, y: screen.frame.midY - h / 2, width: w, height: h)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func close() { panel.close() }
}
