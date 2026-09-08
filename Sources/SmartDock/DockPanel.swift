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

/// Scroll state for an overflowing bar: the content slides by `offset` along the
/// main axis. `maxOffset` is set by DockPanel from measured content vs. panel
/// length; 0 means everything fits and the bar behaves exactly as before.
final class ScrollModel: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var maxOffset: CGFloat = 0
    var dragging = false   // reorder in progress → scroll input ignored

    func scroll(by delta: CGFloat) {
        let next = min(max(0, offset + delta), maxOffset)
        if next != offset { offset = next }
    }

    /// Re-pin after content or geometry changes (windows closed, settings edits…).
    func clamp() {
        let next = min(max(0, offset), maxOffset)
        if next != offset { offset = next }
    }
}

/// The bar's hosting view, extended to catch scroll-wheel input. The panel never
/// becomes key, but scroll events follow the pointer, so they land here anyway.
/// Events are always consumed: the bar floats over app windows, and scrolling on
/// it must not fall through to whatever sits underneath.
private final class ScrollHostingView: NSHostingView<DockView> {
    var onScroll: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
}

/// A borderless, non-activating bar pinned to the bottom of one screen.
final class DockPanel {
    let displayUUID: String?
    var frame: NSRect { panel.frame }
    private let panel: NSPanel
    private let hosting: ScrollHostingView
    private let screen: NSScreen
    private let store: OrderStore
    private var lastWindows: [WindowInfo]?
    private var lastSettings = BarSettings()
    private let cursorSentinel = CursorSentinel()
    private let hoverModel = HoverModel()
    private let scrollModel = ScrollModel()

    init(screen: NSScreen, store: OrderStore) {
        self.screen = screen
        self.store = store
        displayUUID = screen.displayUUID
        hosting = ScrollHostingView(rootView: DockView(windows: [], store: store, settings: BarSettings(),
                                                       hover: HoverModel(), scroll: ScrollModel()))
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
        hosting.onScroll = { [weak self] event in self?.handleScroll(event) }
    }

    /// Scroll input → offset. Trackpads (and their momentum tail) deliver precise
    /// point deltas; classic mouse wheels deliver line counts, scaled up here.
    private func handleScroll(_ event: NSEvent) {
        guard scrollModel.maxOffset > 0, !scrollModel.dragging else { return }
        let vertical = lastSettings.position != .bottom
        // Bottom bars accept both axes (mouse wheel = Y, trackpad pan = X); side bars only Y.
        let raw = vertical ? event.scrollingDeltaY : event.scrollingDeltaX + event.scrollingDeltaY
        let delta = event.hasPreciseScrollingDeltas ? raw : raw * 16
        scrollModel.scroll(by: -delta)
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
        hosting.rootView = DockView(windows: windows, store: store, settings: lastSettings,
                                    hover: hoverModel, scroll: scrollModel)
        guard !windows.isEmpty else {
            updateScrollBounds(maxOffset: 0)
            return panel.orderOut(nil)
        }

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

        // Content longer than the panel scrolls into view; anything else pins at 0.
        let viewport = lastSettings.position == .bottom ? frame.width : frame.height
        let overflow = CGFloat(lastSettings.contentLength(count: windows.count)) - viewport
        updateScrollBounds(maxOffset: overflow > 0.5 ? overflow : 0)   // tolerate rounding noise
    }

    private func updateScrollBounds(maxOffset: CGFloat) {
        if scrollModel.maxOffset != maxOffset { scrollModel.maxOffset = maxOffset }
        scrollModel.clamp()
    }

    func close() { panel.close() }
}
