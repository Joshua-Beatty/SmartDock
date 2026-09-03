import AppKit

enum Debug {
    static let cursor = CommandLine.arguments.contains("--debug-cursor")
    static let settings = CommandLine.arguments.contains("--debug-settings")

    static func log(_ msg: @autoclosure () -> String) {
        guard cursor else { return }
        NSLog("[cursor] %@", msg())
    }

    static func slog(_ msg: @autoclosure () -> String) {
        guard settings else { return }
        NSLog("[settings] %@", msg())
    }

    static func describeCursor(_ c: NSCursor?) -> String {
        guard let c else { return "nil" }
        let known: [(String, NSCursor)] = [
            ("arrow", .arrow), ("iBeam", .iBeam), ("pointingHand", .pointingHand),
            ("resizeUpDown", .resizeUpDown), ("resizeLeftRight", .resizeLeftRight),
            ("resizeUp", .resizeUp), ("resizeDown", .resizeDown),
            ("resizeLeft", .resizeLeft), ("resizeRight", .resizeRight),
            ("crosshair", .crosshair), ("openHand", .openHand), ("closedHand", .closedHand),
        ]
        for (name, k) in known where k == c || k.image === c.image { return name }
        return "other(hotSpot: \(c.hotSpot), imageSize: \(c.image.size))"
    }
}
