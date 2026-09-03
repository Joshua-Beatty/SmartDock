import AppKit
import ApplicationServices

// The system prompt is the one and only permission dialog — it also registers
// SmartDock in the Accessibility list. Ongoing "still missing" state is surfaced
// via the menu bar icon instead (see DockController.updateTrustUI).
let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if !AXIsProcessTrustedWithOptions(axOptions) {
    NSLog("SmartDock: Accessibility permission required — grant it in System Settings > Privacy & Security > Accessibility, then relaunch.")
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
CursorRights.enableBackgroundCursor()

let dock = DockController()
dock.start()

app.run()
