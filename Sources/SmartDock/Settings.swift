import AppKit
import SwiftUI

/// Codable sRGB color.
struct RGBA: Codable, Equatable {
    var r = 0.0, g = 0.0, b = 0.0, a = 0.0

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init() {}
    init(_ c: Color) {
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
        r = ns.redComponent; g = ns.greenComponent; b = ns.blueComponent; a = ns.alphaComponent
    }
}

enum BarPosition: String, Codable, CaseIterable {
    case bottom, left, right
}

enum BarAlignment: String, Codable, CaseIterable {
    case start, center, end
}

/// An app pinned to the start of every bar, identified stably by bundle ID.
struct PinnedApp: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }

    /// Icon resolved from the installed app, works while the app is closed.
    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}

/// The settings a bar renders with.
struct BarSettings: Codable, Equatable {
    var textSize: Double = 11
    var backgroundColor = RGBA()          // clear → pure material background
    var position: BarPosition = .bottom
    var thickness: Double = 56            // bar height (bottom) or width (left/right)
    var iconSize: Double = 32
    var itemPadding: Double = 6           // inner: content ↔ item edge
    var itemMargin: Double = 2            // outer: gap between items
    var pinned: [PinnedApp] = []
    var fullSpan = false                  // bar spans the whole screen edge, square corners
    var itemLength: Double = 0            // along the bar axis; 0 = auto
    var itemAlignment: BarAlignment = .center   // content placement when fullSpan

    init() {}

    // Tolerate settings saved by older builds that lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textSize = try c.decodeIfPresent(Double.self, forKey: .textSize) ?? 11
        backgroundColor = try c.decodeIfPresent(RGBA.self, forKey: .backgroundColor) ?? RGBA()
        position = try c.decodeIfPresent(BarPosition.self, forKey: .position) ?? .bottom
        thickness = try c.decodeIfPresent(Double.self, forKey: .thickness) ?? 56
        iconSize = try c.decodeIfPresent(Double.self, forKey: .iconSize) ?? 32
        itemPadding = try c.decodeIfPresent(Double.self, forKey: .itemPadding) ?? 6
        itemMargin = try c.decodeIfPresent(Double.self, forKey: .itemMargin) ?? 2
        pinned = try c.decodeIfPresent([PinnedApp].self, forKey: .pinned) ?? []
        fullSpan = try c.decodeIfPresent(Bool.self, forKey: .fullSpan) ?? false
        itemLength = try c.decodeIfPresent(Double.self, forKey: .itemLength) ?? 0
        itemAlignment = try c.decodeIfPresent(BarAlignment.self, forKey: .itemAlignment) ?? .center
    }
}

// MARK: - Main-axis geometry (single source of truth for DockView layout and DockPanel scrolling)

extension BarSettings {
    /// One item's length along the bar axis — mirrors DockView's itemWidth/itemHeight.
    var mainItemLength: Double {
        if itemLength > 0 { return itemLength }
        return position == .bottom ? 150 : iconSize + 2 * itemPadding
    }
    /// Item length plus the inter-item gap: the bar's uniform slot unit.
    var mainSlot: Double { mainItemLength + itemMargin }
    /// Total content extent of `count` items, including the bar's edge padding.
    func contentLength(count: Int) -> Double { itemMargin + Double(count) * mainSlot }
}

/// Per-monitor overrides; nil fields follow the defaults.
struct MonitorSettings: Codable, Equatable {
    var name: String
    var textSize: Double?
    var backgroundColor: RGBA?
    var position: BarPosition?
    var thickness: Double?
    var iconSize: Double?
    var itemPadding: Double?
    var itemMargin: Double?
    var pinned: [PinnedApp]?
    var fullSpan: Bool?
    var itemLength: Double?
    var itemAlignment: BarAlignment?
}

final class SettingsStore: ObservableObject {
    /// Dev runs (`swift run`, no bundle ID) write to the installed app's domain too,
    /// so there is exactly one settings pool no matter how SmartDock is launched.
    private static let prefs: UserDefaults = Bundle.main.bundleIdentifier != nil
        ? .standard
        : UserDefaults(suiteName: "com.smartdock.SmartDock") ?? .standard

    @Published var defaults = BarSettings() { didSet { save() } }
    @Published var monitors: [String: MonitorSettings] = [:] { didSet { save() } }   // key: display UUID
    @Published var interceptZoom = false { didSet { save() } }   // green-button interception (global)
    @Published var connected: Set<String> = []   // not persisted

    init() {
        // Assign via the Published backing storage: plain `property = v` here would
        // run the wrapper's setter → didSet → save(), which persists the still-empty
        // `monitors` before it has been loaded — wiping all overrides on every launch.
        let dec = JSONDecoder()
        if let d = Self.prefs.data(forKey: "defaults"),
           let v = try? dec.decode(BarSettings.self, from: d) { _defaults = Published(initialValue: v) }
        if let d = Self.prefs.data(forKey: "monitors"),
           let v = try? dec.decode([String: MonitorSettings].self, from: d) { _monitors = Published(initialValue: v) }
        _interceptZoom = Published(initialValue: Self.prefs.bool(forKey: "interceptZoom"))
        Debug.slog("loaded defaults=\(Self.prefs.data(forKey: "defaults")?.count ?? -1)B monitors=\(Self.prefs.data(forKey: "monitors")?.count ?? -1)B → \(overrideSummary())")
    }

    private func overrideSummary() -> String {
        monitors.map { _, m in
            var f: [String] = []
            if m.textSize != nil { f.append("text") }
            if m.backgroundColor != nil { f.append("bg") }
            if m.position != nil { f.append("pos") }
            if m.thickness != nil { f.append("thick") }
            if m.iconSize != nil { f.append("icon") }
            if m.itemPadding != nil { f.append("pad") }
            if m.itemMargin != nil { f.append("margin") }
            if let p = m.pinned { f.append("pinned(\(p.count))") }
            if m.fullSpan != nil { f.append("full") }
            if m.itemLength != nil { f.append("len") }
            if m.itemAlignment != nil { f.append("align") }
            return "\(m.name):[\(f.joined(separator: ","))]"
        }.sorted().joined(separator: " ")
    }

    /// Track a display forever once seen — entries survive the monitor being off.
    func register(uuid: String, name: String) {
        if monitors[uuid] == nil { monitors[uuid] = MonitorSettings(name: name) }
        else if monitors[uuid]?.name != name { monitors[uuid]?.name = name }
    }

    /// Defaults with this monitor's overrides applied.
    func effective(for uuid: String?) -> BarSettings {
        var s = defaults
        if let uuid, let m = monitors[uuid] {
            if let t = m.textSize { s.textSize = t }
            if let c = m.backgroundColor { s.backgroundColor = c }
            if let p = m.position { s.position = p }
            if let th = m.thickness { s.thickness = th }
            if let i = m.iconSize { s.iconSize = i }
            if let p = m.itemPadding { s.itemPadding = p }
            if let g = m.itemMargin { s.itemMargin = g }
            if let pin = m.pinned { s.pinned = pin }
            if let f = m.fullSpan { s.fullSpan = f }
            if let l = m.itemLength { s.itemLength = l }
            if let a = m.itemAlignment { s.itemAlignment = a }
        }
        return s
    }

    private func save() {
        let enc = JSONEncoder()
        let d = try? enc.encode(defaults)
        let m = try? enc.encode(monitors)
        Self.prefs.set(d, forKey: "defaults")
        Self.prefs.set(m, forKey: "monitors")
        Self.prefs.set(interceptZoom, forKey: "interceptZoom")
        Debug.slog("save defaults=\(d?.count ?? -1)B monitors=\(m?.count ?? -1)B → \(overrideSummary())")
    }
}

extension NSScreen {
    /// Stable identity for a physical display across disconnects and reboots.
    var displayUUID: String? {
        guard let num = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
