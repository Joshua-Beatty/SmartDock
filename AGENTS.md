# SmartDock

macOS per-monitor Dock replacement: one borderless `NSPanel` per display showing that screen's windows, tracked via the Accessibility API (1s poll + workspace notifications). Swift Package, SwiftUI hosted in AppKit, macOS 13+.

## Patterns

- **Pipeline:** `DockController.refresh()` → AX window list → `OrderStore.arrange()` → `DockPanel.update()` → sets `hosting.rootView` (`DockView`) and frames the panel.
- **The panel is never key/active**, so SwiftUI hover and scroll don't work. AppKit feeds events in through small `ObservableObject`s (`HoverModel`, `ScrollModel`) owned by `DockPanel`.
- **Hand-rolled geometry:** hover, drag-reorder, and scrolling all use uniform-slot math. Single source of truth: `BarSettings.mainItemLength/mainSlot/contentLength` in Settings.swift.
- **Settings:** `BarSettings` defaults + per-monitor optional overrides (`MonitorSettings`), merged by `SettingsStore.effective(for:)`. New fields need: both structs, `effective`, decode fallback, `quantize()` if numeric, SettingsView rows, and `BarProfile` in SettingsTransfer.swift.
- **Numeric values are quantized** to `SettingStep` steps at every entry point (UI, load, paste, import).
- Comments explain *why* — keep that style.

## Reinstall & relaunch

```sh
scripts/build-release.sh                       # builds + signs dist/SmartDock.app
osascript -e 'tell application "SmartDock" to quit'
rm -rf /Applications/SmartDock.app && cp -R dist/SmartDock.app /Applications/
open -a /Applications/SmartDock.app
```

Signing uses the stable "SmartDock Code Signing" identity, so the Accessibility grant survives reinstalls. Dev runs (`swift run`) share the installed app's settings domain.
