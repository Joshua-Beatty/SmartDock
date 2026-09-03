import Foundation

/// A partial bar configuration — the unit of copy/paste. Copied from a monitor it
/// carries only that monitor's overridden fields; copied from Defaults it carries
/// every field. Pasting applies exactly the carried fields.
struct BarProfile: Codable {
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

    init(overrides m: MonitorSettings) {
        textSize = m.textSize
        backgroundColor = m.backgroundColor
        position = m.position
        thickness = m.thickness
        iconSize = m.iconSize
        itemPadding = m.itemPadding
        itemMargin = m.itemMargin
        pinned = m.pinned
        fullSpan = m.fullSpan
        itemLength = m.itemLength
        itemAlignment = m.itemAlignment
    }

    init(complete s: BarSettings) {
        textSize = s.textSize
        backgroundColor = s.backgroundColor
        position = s.position
        thickness = s.thickness
        iconSize = s.iconSize
        itemPadding = s.itemPadding
        itemMargin = s.itemMargin
        pinned = s.pinned
        fullSpan = s.fullSpan
        itemLength = s.itemLength
        itemAlignment = s.itemAlignment
    }

    /// Overlay the carried fields onto defaults.
    func applied(to s: inout BarSettings) {
        if let v = textSize { s.textSize = v }
        if let v = backgroundColor { s.backgroundColor = v }
        if let v = position { s.position = v }
        if let v = thickness { s.thickness = v }
        if let v = iconSize { s.iconSize = v }
        if let v = itemPadding { s.itemPadding = v }
        if let v = itemMargin { s.itemMargin = v }
        if let v = pinned { s.pinned = v }
        if let v = fullSpan { s.fullSpan = v }
        if let v = itemLength { s.itemLength = v }
        if let v = itemAlignment { s.itemAlignment = v }
    }

    /// The carried fields as a monitor's exact override set.
    func asOverrides(name: String) -> MonitorSettings {
        MonitorSettings(name: name,
                        textSize: textSize,
                        backgroundColor: backgroundColor,
                        position: position,
                        thickness: thickness,
                        iconSize: iconSize,
                        itemPadding: itemPadding,
                        itemMargin: itemMargin,
                        pinned: pinned,
                        fullSpan: fullSpan,
                        itemLength: itemLength,
                        itemAlignment: itemAlignment)
    }
}

struct TransferEnvelope: Codable {
    var smartdock = 1
    var kind: String   // "profile" | "all"
    var profile: BarProfile?
    var all: AllPayload?

    struct AllPayload: Codable {
        var defaults: BarSettings
        var monitors: [String: MonitorSettings]
        var interceptZoom: Bool
    }
}

enum TransferError: LocalizedError {
    case invalidPayload, newerVersion, notAProfile, notABackup

    var errorDescription: String? {
        switch self {
        case .invalidPayload: return "No SmartDock settings found"
        case .newerVersion: return "Made by a newer SmartDock version"
        case .notAProfile: return "That's a full backup — import it from General"
        case .notABackup: return "That's a profile — paste it on Defaults or a monitor"
        }
    }
}

extension SettingsStore {
    private static func encode<T: Encodable>(_ value: T) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(value)) ?? Data()
    }

    private static func decodeEnvelope(_ data: Data) throws -> TransferEnvelope {
        guard let env = try? JSONDecoder().decode(TransferEnvelope.self, from: data) else {
            throw TransferError.invalidPayload
        }
        guard env.smartdock <= 1 else { throw TransferError.newerVersion }
        return env
    }

    // MARK: - Profiles (clipboard unit; uuid nil = Defaults page)

    func copyProfile(for uuid: String?) -> String {
        let profile: BarProfile
        if let uuid, let m = monitors[uuid] { profile = BarProfile(overrides: m) }
        else { profile = BarProfile(complete: defaults) }
        let env = TransferEnvelope(kind: "profile", profile: profile, all: nil)
        return String(data: Self.encode(env), encoding: .utf8) ?? ""
    }

    func pasteProfile(_ json: String, to uuid: String?) throws {
        let env = try Self.decodeEnvelope(Data(json.utf8))
        guard env.kind == "profile", let profile = env.profile else { throw TransferError.notAProfile }
        if let uuid {
            let name = monitors[uuid]?.name ?? "Monitor"
            monitors[uuid] = profile.asOverrides(name: name)
        } else {
            var d = defaults
            profile.applied(to: &d)
            defaults = d
        }
    }

    // MARK: - Full backup (file unit)

    func exportAll() -> Data {
        Self.encode(TransferEnvelope(
            kind: "all", profile: nil,
            all: .init(defaults: defaults, monitors: monitors, interceptZoom: interceptZoom)))
    }

    func importAll(_ data: Data) throws {
        let env = try Self.decodeEnvelope(data)
        guard env.kind == "all", let all = env.all else { throw TransferError.notABackup }
        defaults = all.defaults
        monitors = all.monitors
        interceptZoom = all.interceptZoom
    }
}
