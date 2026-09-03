import AppKit

// Private CoreGraphics (SkyLight) API. Without this connection property the window
// server ignores cursor changes from apps that aren't frontmost — and SmartDock never
// is (accessory app, non-activating panels). Long-established background-utility trick.
private typealias CGSConnectionID = Int32

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> CGSConnectionID

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: CGSConnectionID, _ target: CGSConnectionID,
                                      _ key: CFString, _ value: CFTypeRef) -> CGError

enum CursorRights {
    static func enableBackgroundCursor() {
        let cid = _CGSDefaultConnection()
        let err = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        Debug.log("SetsCursorInBackground → \(err.rawValue)")
        if err != .success { NSLog("SmartDock: SetsCursorInBackground failed (\(err.rawValue))") }
    }
}
