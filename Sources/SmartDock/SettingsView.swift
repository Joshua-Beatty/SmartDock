import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPage: Hashable {
    case general, defaults, monitor(String)
}

/// Login-item registration via SMAppService — only meaningful for the installed
/// .app bundle (dev runs via `swift run` have no bundle identifier).
private enum LaunchAtLogin {
    static var available: Bool { Bundle.main.bundleIdentifier != nil }
    static var isEnabled: Bool { available && SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("SmartDock: launch-at-login change failed: %@", "\(error)")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var page: SettingsPage? = .general

    private var monitorEntries: [(id: String, name: String, online: Bool)] {
        store.monitors
            .map { (id: $0.key, name: $0.value.name, online: store.connected.contains($0.key)) }
            .sorted { ($0.online ? 0 : 1, $0.name) < ($1.online ? 0 : 1, $1.name) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Label("General", systemImage: "gearshape").tag(SettingsPage.general)
                Label("Default Settings", systemImage: "slider.horizontal.3").tag(SettingsPage.defaults)
                Divider()
                ForEach(monitorEntries, id: \.id) { entry in
                    HStack {
                        Label(entry.name, systemImage: "display")
                        Spacer()
                        if !entry.online {
                            Text("Offline").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(SettingsPage.monitor(entry.id))
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch page {
            case .defaults: DefaultsSettingsView(store: store)
            case .monitor(let id): MonitorSettingsView(store: store, id: id)
            default: GeneralSettingsView(store: store)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// A monospaced command snippet with a copy button.
private struct CommandBlock: View {
    let title: String
    let commands: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commands, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
            }
            Text(commands)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
        .padding(.vertical, 4)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var backupStatus: String?
    @State private var backupFailed = false

    private static let hideDock = """
    defaults write com.apple.dock autohide -bool true && killall Dock
    defaults write com.apple.dock autohide-delay -float 1000 && killall Dock
    defaults write com.apple.dock no-bouncing -bool TRUE && killall Dock
    """

    private static let restoreDock = """
    defaults write com.apple.dock autohide -bool false && killall Dock
    defaults delete com.apple.dock autohide-delay && killall Dock
    defaults write com.apple.dock no-bouncing -bool FALSE && killall Dock
    """

    var body: some View {
        Form {
            Section {
                Text("A per-monitor dock replacement. Each display gets its own bar showing the windows on that screen. Configure shared defaults, or override them for a specific monitor from the sidebar.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("SmartDock")
            }
            Section {
                Toggle("Launch at startup", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        LaunchAtLogin.set(on)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }))
                    .disabled(!LaunchAtLogin.available)
            } footer: {
                Text(LaunchAtLogin.available
                     ? "Starts SmartDock automatically when you log in."
                     : "Available when running the installed app (scripts/build-release.sh → DMG → Applications).")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Intercept the green maximize button", isOn: $store.interceptZoom)
            } footer: {
                Text("Clicking a window's green button fills the screen beside the bar instead of entering full screen. Click it again to restore the previous size. Hold ⌥ while clicking for the native behavior.")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Export All Settings…") { exportAll() }
                    Button("Import All Settings…") { importAll() }
                    if let backupStatus {
                        Text(backupStatus).font(.caption)
                            .foregroundStyle(backupFailed ? .red : .secondary)
                    }
                    Spacer()
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Everything in one file: defaults, every monitor's overrides, and general options. Importing replaces all settings.")
                    .foregroundStyle(.secondary)
            }
            Section {
                CommandBlock(title: "Hide the macOS Dock", commands: Self.hideDock)
                CommandBlock(title: "Restore the macOS Dock", commands: Self.restoreDock)
            } header: {
                Text("macOS Dock")
            } footer: {
                Text("SmartDock can't remove Apple's Dock (the system protects it). Run these in Terminal to keep it out of the way — auto-hidden with an enormous reveal delay and no bouncing — or to bring it back.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func exportAll() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SmartDock-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportAll().write(to: url)
            flash("Exported")
        } catch {
            flash("Export failed", failed: true)
        }
    }

    private func importAll() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        let alert = NSAlert()
        alert.messageText = "Replace all SmartDock settings?"
        alert.informativeText = "Defaults, every monitor's overrides, and general options will be replaced by the imported file."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.importAll(data)
            flash("Imported")
        } catch {
            flash(error.localizedDescription, failed: true)
        }
    }

    private func flash(_ message: String, failed: Bool = false) {
        backupFailed = failed
        backupStatus = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { backupStatus = nil }
    }
}

// MARK: - Shared row controls

private struct PositionControl: View {
    @Binding var position: BarPosition
    var body: some View {
        Picker("", selection: $position) {
            Text("Bottom").tag(BarPosition.bottom)
            Text("Left").tag(BarPosition.left)
            Text("Right").tag(BarPosition.right)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
    }
}

/// Slider + exact-entry field, both snapped to `step`. Integer-step settings show
/// whole numbers; 0.1-step settings always show one decimal — the precision of
/// each setting is visible at a glance (and spelled out in the field's tooltip).
private struct NumberControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    private var decimals: Int { step < 0.05 ? 2 : step < 0.5 ? 1 : 0 }

    /// Everything written through here lands clamped and step-aligned.
    private var quantized: Binding<Double> {
        Binding(get: { value },
                set: { value = min(max($0, range.lowerBound), range.upperBound).quantized(step) })
    }

    var body: some View {
        Slider(value: quantized, in: range)
        TextField("", value: quantized, format: .number.precision(.fractionLength(decimals)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 58)
            .help(help)
        Text("pt").foregroundStyle(.secondary)
    }

    private var help: String {
        let f = { (v: Double) in v.formatted(.number.precision(.fractionLength(0...decimals))) }
        return "\(f(range.lowerBound))–\(f(range.upperBound)) pt, in steps of \(f(step)) pt"
    }
}

private struct AlignmentControl: View {
    @Binding var alignment: BarAlignment
    var body: some View {
        Picker("", selection: $alignment) {
            Text("Start").tag(BarAlignment.start)
            Text("Center").tag(BarAlignment.center)
            Text("End").tag(BarAlignment.end)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
    }
}

/// Slider with exact entry and an Auto reset; 0 encodes "auto" (150 pt effective).
/// Editing either control leaves auto mode; clearing the field (or typing "auto")
/// returns to it. Whole points, like the other length settings.
private struct AutoLengthControl: View {
    @Binding var value: Double
    @FocusState private var focused: Bool
    @State private var text = ""

    private let range: ClosedRange<Double> = 20...400

    var body: some View {
        Slider(value: Binding(get: { value == 0 ? 150 : value },
                              set: { value = $0.quantized(SettingStep.itemLength) }),
               in: range)
        TextField("Auto", text: $text)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { if !$0 { commit() } }
            .onChange(of: value) { _ in if !focused { sync() } }
            .onAppear(perform: sync)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 58)
            .help("\(Int(range.lowerBound))–\(Int(range.upperBound)) pt, in steps of 1 pt — leave empty for Auto")
        Text("pt").foregroundStyle(.secondary)
        Button("Auto") { value = 0 }
            .disabled(value == 0)
    }

    private func sync() {
        text = value == 0 ? "" : value.formatted(.number.precision(.fractionLength(0)))
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "auto" {
            value = 0
        } else if let v = try? Double(trimmed, format: .number) {
            value = min(max(v, range.lowerBound), range.upperBound).quantized(SettingStep.itemLength)
        }
        sync()   // parse failure or clamping: the field falls back to the stored value
    }
}

/// Copy/Paste a bar profile via the clipboard. uuid nil = the Defaults page.
private struct ProfileTransferRow: View {
    let store: SettingsStore
    let uuid: String?
    @State private var status: String?
    @State private var failed = false

    var body: some View {
        HStack {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.copyProfile(for: uuid), forType: .string)
                flash("Copied")
            }
            Button("Paste") {
                do {
                    try store.pasteProfile(NSPasteboard.general.string(forType: .string) ?? "", to: uuid)
                    flash("Applied")
                } catch {
                    flash(error.localizedDescription, failed: true)
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(failed ? .red : .secondary)
            }
            Spacer()
        }
    }

    private func flash(_ message: String, failed: Bool = false) {
        self.failed = failed
        status = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { status = nil }
    }
}

/// Reorderable pinned-apps table rows + an add-menu of currently open apps.
private struct PinnedTable: View {
    @Binding var pinned: [PinnedApp]

    private var candidates: [PinnedApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bid = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return PinnedApp(bundleID: bid, name: name)
            }
            .filter { c in !pinned.contains(where: { $0.bundleID == c.bundleID }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ForEach(pinned) { app in
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                Text(app.name)
                Spacer()
                Button {
                    pinned.removeAll { $0.bundleID == app.bundleID }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Unpin \(app.name)")
            }
        }
        .onMove { pinned.move(fromOffsets: $0, toOffset: $1) }

        Menu {
            if candidates.isEmpty {
                Text("All open applications are pinned")
            }
            ForEach(candidates) { candidate in
                Button(candidate.name) { pinned.append(candidate) }
            }
        } label: {
            Label("Add Application", systemImage: "plus")
        }
    }
}

struct DefaultsSettingsView: View {
    @ObservedObject var store: SettingsStore

    private var bg: Binding<Color> {
        Binding(get: { store.defaults.backgroundColor.color },
                set: { store.defaults.backgroundColor = RGBA($0) })
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Position").frame(width: 130, alignment: .leading)
                    PositionControl(position: $store.defaults.position)
                    Spacer()
                }
                HStack {
                    Text("Full Width/Height").frame(width: 130, alignment: .leading)
                    Toggle("", isOn: $store.defaults.fullSpan).labelsHidden()
                    Spacer()
                }
                HStack {
                    Text("Item Alignment").frame(width: 130, alignment: .leading)
                    AlignmentControl(alignment: $store.defaults.itemAlignment)
                        .disabled(!store.defaults.fullSpan)
                    Spacer()
                }
                HStack {
                    Text("Bar Thickness").frame(width: 130, alignment: .leading)
                    NumberControl(value: $store.defaults.thickness, range: 36...280,
                                  step: SettingStep.thickness)
                }
                HStack {
                    Text("Item Length").frame(width: 130, alignment: .leading)
                    AutoLengthControl(value: $store.defaults.itemLength)
                }
                HStack {
                    Text("Icon Size").frame(width: 130, alignment: .leading)
                    NumberControl(value: $store.defaults.iconSize, range: 16...64,
                                  step: SettingStep.iconSize)
                }
                HStack {
                    Text("Text Size").frame(width: 130, alignment: .leading)
                    NumberControl(value: $store.defaults.textSize, range: 9...20,
                                  step: SettingStep.textSize)
                }
                HStack {
                    Text("Item Padding").frame(width: 130, alignment: .leading)
                    NumberControl(value: $store.defaults.itemPadding, range: 0...24,
                                  step: SettingStep.itemPadding)
                }
                HStack {
                    Text("Item Margin").frame(width: 130, alignment: .leading)
                    NumberControl(value: $store.defaults.itemMargin, range: 0...24,
                                  step: SettingStep.itemMargin)
                }
                HStack {
                    Text("Background Color").frame(width: 130, alignment: .leading)
                    ColorPicker("", selection: bg, supportsOpacity: true).labelsHidden()
                    Spacer()
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("Applied to every monitor unless overridden.").foregroundStyle(.secondary)
            }

            Section {
                PinnedTable(pinned: $store.defaults.pinned)
            } header: {
                Text("Pinned Applications")
            } footer: {
                Text("Pinned apps stay at the start of the bar, in this order, and remain visible when closed — click one to launch it. Drag rows to reorder.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ProfileTransferRow(store: store, uuid: nil)
            } header: {
                Text("Profile")
            } footer: {
                Text("Copy puts these defaults on the clipboard as a profile; paste one from any monitor to apply its overridden fields here.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct MonitorSettingsView: View {
    @ObservedObject var store: SettingsStore
    let id: String

    // Toggle on = override present. Editing a control writes the override,
    // which flips the toggle on automatically. Toggle off = back to default.
    private func enabled<T>(_ kp: WritableKeyPath<MonitorSettings, T?>,
                            _ def: KeyPath<BarSettings, T>) -> Binding<Bool> {
        Binding(get: { store.monitors[id]?[keyPath: kp] != nil },
                set: {
                    Debug.slog("override toggle=\($0) monitor=\(id) entryExists=\(store.monitors[id] != nil)")
                    store.monitors[id]?[keyPath: kp] = $0 ? store.defaults[keyPath: def] : nil
                })
    }

    private func value<T>(_ kp: WritableKeyPath<MonitorSettings, T?>,
                          _ def: KeyPath<BarSettings, T>) -> Binding<T> {
        Binding(get: { store.monitors[id]?[keyPath: kp] ?? store.defaults[keyPath: def] },
                set: {
                    Debug.slog("override write monitor=\(id) entryExists=\(store.monitors[id] != nil)")
                    store.monitors[id]?[keyPath: kp] = $0
                })
    }

    private var bgColor: Binding<Color> {
        let rgba = value(\.backgroundColor, \.backgroundColor)
        return Binding(get: { rgba.wrappedValue.color },
                       set: { rgba.wrappedValue = RGBA($0) })
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle("", isOn: enabled(\.position, \.position)).labelsHidden()
                    Text("Position").frame(width: 130, alignment: .leading)
                    PositionControl(position: value(\.position, \.position))
                    Spacer()
                }
                HStack {
                    Toggle("", isOn: enabled(\.fullSpan, \.fullSpan)).labelsHidden()
                    Text("Full Width/Height").frame(width: 130, alignment: .leading)
                    Toggle("", isOn: value(\.fullSpan, \.fullSpan)).labelsHidden()
                    Spacer()
                }
                HStack {
                    Toggle("", isOn: enabled(\.itemAlignment, \.itemAlignment)).labelsHidden()
                    Text("Item Alignment").frame(width: 130, alignment: .leading)
                    AlignmentControl(alignment: value(\.itemAlignment, \.itemAlignment))
                        .disabled(!value(\.fullSpan, \.fullSpan).wrappedValue)
                    Spacer()
                }
                HStack {
                    Toggle("", isOn: enabled(\.thickness, \.thickness)).labelsHidden()
                    Text("Bar Thickness").frame(width: 130, alignment: .leading)
                    NumberControl(value: value(\.thickness, \.thickness), range: 36...280,
                                  step: SettingStep.thickness)
                }
                HStack {
                    Toggle("", isOn: enabled(\.itemLength, \.itemLength)).labelsHidden()
                    Text("Item Length").frame(width: 130, alignment: .leading)
                    AutoLengthControl(value: value(\.itemLength, \.itemLength))
                }
                HStack {
                    Toggle("", isOn: enabled(\.iconSize, \.iconSize)).labelsHidden()
                    Text("Icon Size").frame(width: 130, alignment: .leading)
                    NumberControl(value: value(\.iconSize, \.iconSize), range: 16...64,
                                  step: SettingStep.iconSize)
                }
                HStack {
                    Toggle("", isOn: enabled(\.textSize, \.textSize)).labelsHidden()
                    Text("Text Size").frame(width: 130, alignment: .leading)
                    NumberControl(value: value(\.textSize, \.textSize), range: 9...20,
                                  step: SettingStep.textSize)
                }
                HStack {
                    Toggle("", isOn: enabled(\.itemPadding, \.itemPadding)).labelsHidden()
                    Text("Item Padding").frame(width: 130, alignment: .leading)
                    NumberControl(value: value(\.itemPadding, \.itemPadding), range: 0...24,
                                  step: SettingStep.itemPadding)
                }
                HStack {
                    Toggle("", isOn: enabled(\.itemMargin, \.itemMargin)).labelsHidden()
                    Text("Item Margin").frame(width: 130, alignment: .leading)
                    NumberControl(value: value(\.itemMargin, \.itemMargin), range: 0...24,
                                  step: SettingStep.itemMargin)
                }
                HStack {
                    Toggle("", isOn: enabled(\.backgroundColor, \.backgroundColor)).labelsHidden()
                    Text("Background Color").frame(width: 130, alignment: .leading)
                    ColorPicker("", selection: bgColor, supportsOpacity: true).labelsHidden()
                    Spacer()
                }
            } header: {
                HStack {
                    Text(store.monitors[id]?.name ?? "Monitor")
                    if !store.connected.contains(id) {
                        Text("(offline)").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Enable a toggle to override the default for this monitor; turn it off to follow the default.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Toggle("", isOn: enabled(\.pinned, \.pinned)).labelsHidden()
                    Text("Override pinned applications")
                    Spacer()
                }
                PinnedTable(pinned: value(\.pinned, \.pinned))
            } header: {
                Text("Pinned Applications")
            } footer: {
                Text("When overridden, this monitor uses its own pinned list instead of the default. Editing the list enables the override automatically.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ProfileTransferRow(store: store, uuid: id)
            } header: {
                Text("Profile")
            } footer: {
                Text("Copy puts this monitor's overrides on the clipboard; paste replaces this monitor's overrides with the clipboard profile (fields it doesn't carry follow the defaults).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
