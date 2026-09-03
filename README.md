# SmartDock

A per-monitor dock replacement for macOS. Every display gets its own bar showing the
windows on that screen — window titles included — with per-monitor styling, pinned
apps, and drag reordering.

## Features

- **Per-window entries** — each window is its own item (icon + window title), tracked
  via the Accessibility API. Click to focus that exact window; minimized windows stay
  visible (dimmed) and restore on click.
- **Drag to rearrange** — windows of the same app stay grouped: drag within an app to
  reorder its windows, drag past another app and the whole group moves, with live
  drop preview. New windows append to the end.
- **Pinned applications** — pinned apps hold the start of the bar in a configurable
  order and remain visible when closed; clicking a closed pin launches it, clicking a
  running one with no windows opens a new window (the Dock's reopen semantics).
- **Per-monitor settings** — defaults plus per-display overrides (toggle per setting):
  position (bottom/left/right), thickness, icon size, text size, item padding/margin,
  item length, full width/height with start/center/end alignment, background color,
  and the pinned list. Monitors are remembered while disconnected.
- **Green-button interception** (optional) — clicking a window's maximize button fills
  the screen beside the bar instead of entering full screen; click again to restore,
  ⌥-click for native behavior.
- **Settings transfer** — export/import everything as JSON, or copy/paste per-bar
  profiles between monitors and defaults via the clipboard.
- Menu bar controls, launch-at-login, and copyable commands for hiding the system
  Dock (System Integrity Protection prevents actually removing it).

## Requirements

- macOS 13+
- **Accessibility permission** — required for window tracking and control. The app
  prompts on first launch; a menu bar warning shows while it's missing. Not
  sandboxable, so not App Store distributable.

## Development

```sh
swift run
```

Debug modes: `swift run SmartDock --debug-cursor` (cursor/tracking diagnostics),
`--debug-settings` (settings load/save tracing). Dev runs share the installed app's
preferences domain (`com.smartdock.SmartDock`).

## Release build

```sh
scripts/build-release.sh [version]   # → dist/SmartDock-<version>.dmg
```

Builds an `.app` bundle, signs it, and wraps it in a DMG with an Applications
symlink. Signing picks the local `SmartDock Code Signing` identity when present,
else the `CODESIGN_ID` env override, else falls back to ad-hoc. A stable signing
identity matters: with ad-hoc, every rebuild looks like a new app to macOS and
Accessibility must be re-granted. (The identity here was created once from a
self-signed cert; `certs/` and its setup script stay untracked.)

## Project layout

```
Sources/SmartDock/
├── main.swift                — bootstrap, permission prompt
├── DockController.swift      — AX window tracking, per-screen state, menu bar
├── DockPanel.swift           — one non-activating panel per display, cursor/hover feed
├── DockView.swift            — the bar UI: items, drag reorder, hover
├── OrderStore.swift          — persistent two-level ordering (apps, windows)
├── Settings.swift            — settings model, per-monitor overrides, persistence
├── SettingsView.swift        — settings window (sidebar: General / Defaults / monitors)
├── SettingsTransfer.swift    — profile copy/paste + full backup import/export
├── MaximizeInterceptor.swift — green-button event tap (research/green-button/)
├── CursorRights.swift        — background cursor-setting (private CGS API)
└── Debug.swift               — opt-in diagnostics
scripts/                      — release packaging
```
