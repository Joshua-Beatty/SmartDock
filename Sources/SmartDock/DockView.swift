import AppKit
import ApplicationServices
import SwiftUI

/// One bar entry: a live window, or (axWindow == nil) a pinned-app placeholder.
struct WindowInfo: Identifiable, Equatable {
    let axWindow: AXUIElement?
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage
    let isMinimized: Bool
    var bundleID: String? = nil   // set for pinned placeholders (launch target)
    var isPinned: Bool = false    // pinned on *this* bar (pin lists are per-monitor)

    var id: Int {
        if let axWindow { return Int(bitPattern: CFHash(axWindow)) }
        return bundleID?.hashValue ?? 0
    }
    static func == (l: Self, r: Self) -> Bool {
        l.id == r.id && l.title == r.title && l.isMinimized == r.isMinimized && l.isPinned == r.isPinned
    }
}

struct DockView: View {
    let windows: [WindowInfo]
    let store: OrderStore
    let settings: BarSettings
    @ObservedObject var hover: HoverModel
    @ObservedObject var scroll: ScrollModel

    // Drag state, all frozen at grab time. Translation is measured in the bar's
    // coordinate space ("bar"), which never moves while the preview reflows.
    @State private var dragID: Int?
    @State private var dragDelta: CGFloat = 0        // along the bar's main axis
    @State private var dragBase: [WindowInfo] = []   // arrangement when the grab started
    @State private var dragFrom: Int = 0             // grabbed item's index in dragBase

    // MARK: - Geometry (uniform slots keep the drag math exact)

    private var vertical: Bool { settings.position != .bottom }
    private var iconSize: CGFloat { CGFloat(settings.iconSize) }
    private var pad: CGFloat { CGFloat(settings.itemPadding) }
    private var margin: CGFloat { CGFloat(settings.itemMargin) }
    private var itemWidth: CGFloat {
        if vertical { return max(24, settings.thickness - 2 * margin) }
        return CGFloat(settings.mainItemLength)
    }
    // Bottom bars: thickness sets the row height (icon centers within, but never clips).
    private var itemHeight: CGFloat {
        if vertical { return CGFloat(settings.mainItemLength) }
        return max(settings.thickness - 2 * margin, iconSize + 2 * pad)
    }
    private var slot: CGFloat { CGFloat(settings.mainSlot) }

    /// Content longer than the panel (DockPanel measured it): the stack pins to the
    /// start edge and slides by the scroll offset instead of following alignment.
    private var overflowing: Bool { scroll.maxOffset > 0 }

    private var spanAlignment: Alignment {
        if overflowing { return vertical ? .top : .leading }
        switch settings.itemAlignment {
        case .start: return vertical ? .top : .leading
        case .center: return .center
        case .end: return vertical ? .bottom : .trailing
        }
    }

    /// Rounded only on the sides facing content — the bar sits flush on the screen edge.
    /// Full-span bars are square; so are overflowing ones, which run edge to edge too.
    private var barShape: AnyShape {
        if settings.fullSpan || overflowing { return AnyShape(Rectangle()) }
        let r: CGFloat = 14
        if #available(macOS 13.3, *) {
            switch settings.position {
            case .bottom:
                return AnyShape(UnevenRoundedRectangle(
                    topLeadingRadius: r, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: r))
            case .left:
                return AnyShape(UnevenRoundedRectangle(
                    topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: r, topTrailingRadius: r))
            case .right:
                return AnyShape(UnevenRoundedRectangle(
                    topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: 0, topTrailingRadius: 0))
            }
        }
        return AnyShape(RoundedRectangle(cornerRadius: r))
    }

    private struct Group: Identifiable {
        let pid: pid_t
        var windows: [WindowInfo]
        var id: pid_t { pid }
    }

    // MARK: - Drag preview

    private var dragTarget: Int? {
        guard dragID != nil, !dragBase.isEmpty else { return nil }
        return max(0, min(dragBase.count - 1, dragFrom + Int((dragDelta / slot).rounded())))
    }

    /// While dragging, render what a drop right now would produce — computed
    /// against the drag-start snapshot, never the live (refreshing) list.
    private var displayed: [WindowInfo] {
        guard let id = dragID else { return windows }
        guard let win = dragBase.first(where: { $0.id == id }),
              let to = dragTarget, to != dragFrom else { return dragBase }
        return store.previewDrop(of: win, from: dragFrom, to: to, in: dragBase)
    }

    /// The grabbed item tracks the cursor: compensate for its shifted preview slot.
    private func offsetAmount(_ win: WindowInfo) -> CGFloat {
        guard win.id == dragID,
              let now = displayed.firstIndex(where: { $0.id == win.id }) else { return 0 }
        return dragDelta - CGFloat(now - dragFrom) * slot
    }

    private var dragPid: pid_t? {
        guard let id = dragID else { return nil }
        return dragBase.first { $0.id == id }?.pid
    }

    /// Hovered item via the same uniform-slot math the drag uses (suppressed mid-drag).
    /// Full-span bars offset the content by alignment — subtract that origin first.
    private var hoveredID: Int? {
        guard dragID == nil, let p = hover.point else { return nil }
        let total = vertical ? hover.barSize.height : hover.barSize.width
        let main = (vertical ? p.y : p.x) - contentOrigin(in: total)
        let idx = Int(((main - margin) / slot).rounded(.down))
        guard idx >= 0, displayed.indices.contains(idx) else { return nil }
        return displayed[idx].id
    }

    private func contentOrigin(in total: CGFloat) -> CGFloat {
        if overflowing { return -scroll.offset }   // start-pinned content, slid by the offset
        guard settings.fullSpan else { return 0 }
        let content = CGFloat(settings.contentLength(count: displayed.count))
        switch settings.itemAlignment {
        case .start: return 0
        case .center: return max(0, (total - content) / 2)
        case .end: return max(0, total - content)
        }
    }

    private func groups(_ list: [WindowInfo]) -> [Group] {
        var out: [Group] = []
        for w in list {
            if out.last?.pid == w.pid { out[out.count - 1].windows.append(w) }
            else { out.append(Group(pid: w.pid, windows: [w])) }
        }
        return out
    }

    // MARK: - Body

    var body: some View {
        let stack = vertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: margin))
            : AnyLayout(HStackLayout(alignment: .top, spacing: margin))

        stack {
            ForEach(groups(displayed)) { group in
                stack {
                    ForEach(group.windows) { item($0) }
                }
                .background {
                    if group.pid == dragPid {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    }
                }
                .zIndex(group.pid == dragPid ? 1 : 0)
            }
        }
        .animation(.easeOut(duration: 0.15), value: displayed.map(\.id))
        .padding(margin)   // the bar's edge inset is the item margin: 0 → fully flush
        // The offset sits inside the frame: content slides, the bar background doesn't.
        .offset(x: vertical ? 0 : -scroll.offset, y: vertical ? -scroll.offset : 0)
        .frame(maxWidth: !vertical && (settings.fullSpan || overflowing) ? .infinity : nil,
               maxHeight: vertical && (settings.fullSpan || overflowing) ? .infinity : nil,
               alignment: spanAlignment)
        .background {
            ZStack {
                barShape.fill(.ultraThinMaterial)
                barShape.fill(settings.backgroundColor.color)   // clear by default → pure material
            }
        }
        .coordinateSpace(name: "bar")
    }

    private func item(_ win: WindowInfo) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: win.icon)
                .resizable()
                .frame(width: iconSize, height: iconSize)
            Text(win.title)
                .font(.system(size: settings.textSize))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, pad)
        .frame(width: itemWidth, height: itemHeight)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(win.id == hoveredID ? 0.12 : 0))
        }
        .animation(.easeOut(duration: 0.12), value: win.id == hoveredID)
        .opacity(win.isMinimized ? 0.45 : 1)
        .offset(x: vertical ? 0 : offsetAmount(win), y: vertical ? offsetAmount(win) : 0)
        .zIndex(win.id == dragID ? 1 : 0)
        .help("\(win.appName) — \(win.title)")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("bar"))
                .onChanged { v in
                    let t = vertical ? v.translation.height : v.translation.width
                    if dragID == nil, abs(t) > 4, win.axWindow != nil,   // placeholders don't drag
                       let idx = windows.firstIndex(where: { $0.id == win.id }) {
                        dragID = win.id
                        dragBase = windows
                        dragFrom = idx
                        scroll.dragging = true   // content must not slide mid-reorder
                    }
                    if dragID == win.id { dragDelta = t }
                }
                .onEnded { _ in
                    let wasDragging = dragID == win.id
                    let base = dragBase
                    let from = dragFrom
                    let to = dragTarget
                    dragID = nil
                    dragDelta = 0
                    dragBase = []
                    scroll.dragging = false
                    guard wasDragging else { return focus(win) }
                    if let to, to != from {
                        store.handleDrop(of: win, from: from, to: to, in: base)
                    }
                }
        )
    }

    private func focus(_ win: WindowInfo) {
        if let axWindow = win.axWindow {
            if win.isMinimized {
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: win.pid)?
                .activate(options: [.activateIgnoringOtherApps])
        } else if let bundleID = win.bundleID,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // Pinned placeholder: open via Launch Services in every case. Not running →
            // launches. Running → activates AND delivers the "reopen" Apple Event (the
            // same thing the Dock sends), which makes apps create a window when they
            // have none — and harmlessly no-op when windows exist on another screen.
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
