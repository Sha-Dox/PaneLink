import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: main window

struct MainWindow: View {
    @ObservedObject var state: AppState
    @AppStorage("mainTab") private var tab = "displays"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if state.needsSetup { SetupCard(state: state) }
            if state.settings.quietFans && !state.fansReady && !state.needsSetup { FanReminder() }
            if state.settings.wakeOnStart && !state.settings.wakeFromOffReady && state.canWake && !state.needsSetup { WakeReminder(state: state) }
            TabView(selection: $tab) {
                DisplaysTab(state: state).tabItem { Label("Displays", systemImage: "display.2") }.tag("displays")
                PerformanceTab(state: state).tabItem { Label("Performance", systemImage: "speedometer") }.tag("performance")
                ControlsTab(state: state).tabItem { Label("Controls", systemImage: "keyboard") }.tag("controls")
                WindowsTab(state: state).tabItem { Label("Windows PC", systemImage: "pc") }.tag("windows")
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 680)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("PaneLink").font(.title.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDot(state: state)
                    Text(state.phaseText).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Spacer()
            if state.connectedHost == nil && !state.isOn {
                if state.canWake { Button("Wake PC") { state.wake(); state.reconnect() } }
                Button("Reconnect") { state.reconnect() }
            }
            Toggle("Extend displays", isOn: Binding(get: { state.isOn }, set: { $0 ? state.start() : state.stop() }))
                .toggleStyle(.switch)
                .controlSize(.large)
                .disabled(!state.isOn && (state.needsSetup || (state.connectedHost == nil && !state.canWake)))
        }
    }
}

private struct Note: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

// MARK: Displays

struct DisplaysTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    if state.monitors.isEmpty {
                        Text(state.connectedHost == nil ? "Waiting for the Windows agent…" : "No monitors reported")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    ForEach(state.monitors) { m in
                        MonitorRow(state: state, monitor: m)
                        if m != state.monitors.last { Divider() }
                    }
                } label: { Text("Windows monitors").font(.headline) }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        ArrangementView(state: state).frame(height: 220)
                        HStack {
                            Note(state.isOn ? "Drag a display to move it. Changes apply immediately and are remembered."
                                            : "Turn on extending to arrange the Windows displays.")
                            Spacer()
                            Button("Match Windows layout") { state.matchWindowsLayout() }.disabled(!state.isOn)
                            Button("Displays Settings…") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                            }
                        }
                    }
                } label: { Text("Arrangement").font(.headline) }

                AlignmentSection(state: state)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Keep the Mac's screen as the main display", isOn: $state.settings.keepMacMain)
                        Toggle("Put windows back on the Windows displays when I turn extending on again", isOn: $state.settings.restoreWindows)
                        if state.settings.restoreWindows {
                            Stepper("…if it's within \(state.settings.restoreMinutes) minutes", value: $state.settings.restoreMinutes, in: 1...240,
                                    step: state.settings.restoreMinutes < 10 ? 1 : 5)
                                .padding(.leading, 20)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("Behaviour").font(.headline) }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: Performance

struct PerformanceTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Low power") {
                Toggle("Low power: always \(state.settings.tuning.lowPowerFps) fps", isOn: $state.settings.lowPowerManual)
                Picker("Low-power frame rate", selection: $state.settings.tuning.lowPowerFps) {
                    Text("60 fps").tag(60); Text("40 fps").tag(40); Text("30 fps").tag(30)
                }
                Toggle("Switch to low power automatically on battery", isOn: $state.settings.lowPowerAuto)
                if state.settings.lowPowerAuto {
                    Stepper("…at or below \(state.settings.lowPowerThreshold)% battery, or in macOS Low Power Mode",
                            value: $state.settings.lowPowerThreshold, in: 5...100, step: 5)
                }
            }
            Section("Wi-Fi") {
                Toggle("Keep Wi-Fi on-channel while streaming (stops the once-a-second hitch; pauses AirDrop/Handoff)", isOn: $state.settings.disableAWDL)
                LabeledContent("Dropout detection") {
                    HStack {
                        Slider(value: Binding(get: { Double(state.settings.tuning.stallMs) }, set: { state.settings.tuning.stallMs = Int($0) }),
                               in: 60...400, step: 20)
                        Text("\(state.settings.tuning.stallMs) ms").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                    }
                }
                Note("How long Windows can go quiet before the Mac pauses sending and resyncs with a fresh frame. Lower recovers faster; raise it if you see needless resyncs.")
            }
            LossSection()
            Section("Stream (applies next time you turn extending on)") {
                Picker("Codec", selection: $state.settings.codec) {
                    Text("HEVC (best quality per bit)").tag(Encoder.Codec.hevc)
                    Text("H.264").tag(Encoder.Codec.h264)
                }
                Toggle("Full-range color (deeper blacks; turn off if blacks look crushed)", isOn: $state.settings.fullRange)
                Toggle("Tear-free on Windows (no tear line; adds ~4 ms on average)", isOn: $state.settings.vsync)
                Picker("Packet-loss protection", selection: $state.settings.fecGroup) {
                    Text("Off").tag(0)
                    Text("Light (6%)").tag(16)
                    Text("Normal (12%)").tag(8)
                    Text("Strong (25%)").tag(4)
                }
            }
            .disabled(state.isOn)
        }
        .formStyle(.grouped)
    }
}

/// Why frames were lost, from the viewers' loss reports (LossLog).
private struct LossSection: View {
    @ObservedObject var log = LossLog.shared
    @State private var range = 3600.0

    var body: some View {
        Section("Lost frames: why") {
            Picker("Period", selection: $range) {
                Text("Last 10 minutes").tag(600.0); Text("Last hour").tag(3600.0); Text("Last day").tag(86400.0); Text("Everything kept").tag(1e9)
            }
            let sum = log.summary(since: Date().addingTimeInterval(-range))
            if sum.isEmpty {
                Note("No losses recorded in this period.")
            } else {
                let total = sum.reduce(0) { $0 + $1.frames }
                ForEach(sum, id: \.cause) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.cause.rawValue).font(.body.weight(.medium))
                            Spacer()
                            Text("\(row.frames) frames · \(row.events)× · \(Int((Double(row.frames) / Double(max(1, total)) * 100).rounded()))%")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Note(row.cause.advice)
                    }
                }
                DisclosureGroup("Latest losses") {
                    ForEach(log.events.suffix(12).reversed()) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(e.at.formatted(date: .omitted, time: .standard)) · \(e.monitor) · \(e.cause.rawValue) · \(e.frames) frames")
                                .font(.caption.weight(.medium))
                            Text(e.detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            HStack {
                Button("Open full log") { log.openFile() }
                Button("Clear") { log.clear() }
            }
        }
    }
}

// MARK: Controls

struct ControlsTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Keyboard shortcuts") {
                Toggle("Enable global shortcuts", isOn: $state.settings.hotkeys)
                ForEach(HotkeyAction.allCases) { a in
                    LabeledContent(a.label) { ShortcutRecorder(state: state, action: a) }
                        .disabled(!state.settings.hotkeys)
                }
                Note("Click a shortcut, then press the new keys (needs ⌘, ⌃ or ⌥). Delete clears it, Esc cancels.")
            }
            Section("Stats overlay") {
                Toggle("Show stats on the Windows displays", isOn: $state.settings.statsOverlay)
                Picker("Position", selection: $state.settings.tuning.overlay.corner) {
                    ForEach(OverlayPrefs.Corner.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("Show") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(OverlayPrefs.Field.allCases) { f in
                            Toggle(f.rawValue, isOn: Binding(
                                get: { state.settings.tuning.overlay.fields.contains(f) },
                                set: { on in
                                    var fs = state.settings.tuning.overlay.fields.filter { $0 != f }
                                    if on { fs.append(f); fs.sort { a, b in OverlayPrefs.Field.allCases.firstIndex(of: a)! < OverlayPrefs.Field.allCases.firstIndex(of: b)! } }
                                    state.settings.tuning.overlay.fields = fs
                                }))
                        }
                    }
                }
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $state.settings.tuning.overlay.fontSize, in: 9...20, step: 0.5)
                        Text(String(format: "%.1f pt", state.settings.tuning.overlay.fontSize)).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Background") {
                    HStack {
                        Slider(value: $state.settings.tuning.overlay.opacity, in: 0...1)
                        Text("\(Int(state.settings.tuning.overlay.opacity * 100))%").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                    }
                }
                Stepper("Turn orange above \(state.settings.tuning.overlay.warnLost) lost frames (per 10 s)",
                        value: $state.settings.tuning.overlay.warnLost, in: 0...500, step: 5)
            }
            Section("Menu bar") {
                Toggle("Low power switch", isOn: $state.settings.tuning.menu.lowPower)
                Toggle("Stats overlay switch", isOn: $state.settings.tuning.menu.statsOverlay)
                Toggle("Wake Windows PC button", isOn: $state.settings.tuning.menu.wake)
                Toggle("Rest Windows PC switch", isOn: $state.settings.tuning.menu.rest)
                Toggle("Monitor list with live stats", isOn: $state.settings.tuning.menu.monitors)
                Toggle("Test pattern button", isOn: $state.settings.tuning.menu.testPattern)
                Toggle("Launch PaneLink at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, press a key combo, done. Esc cancels, Delete clears.
struct ShortcutRecorder: View {
    @ObservedObject var state: AppState
    let action: HotkeyAction
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press keys…" : (state.settings.tuning.shortcuts[action]?.display ?? "None")) {
                recording ? stop() : start()
            }
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 110)
            if action.defaultShortcut != nil && state.settings.tuning.shortcuts[action] != action.defaultShortcut {
                Button("Default") { state.settings.tuning.shortcuts[action] = action.defaultShortcut }.buttonStyle(.link)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        Hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case kVK_Escape: stop(); return nil
            case kVK_Delete, kVK_ForwardDelete: state.settings.tuning.shortcuts[action] = nil; stop(); return nil
            default: break
            }
            let mods = Hotkeys.carbonMods(e.modifierFlags)
            guard mods & UInt32(cmdKey | controlKey | optionKey) != 0 else { NSSound.beep(); return nil }
            let sc = Shortcut(keyCode: UInt32(e.keyCode), mods: mods, key: Hotkeys.keyLabel(e))
            // one shortcut, one action: take it away from whatever had it
            for (a, other) in state.settings.tuning.shortcuts where a != action && other.keyCode == sc.keyCode && other.mods == sc.mods {
                state.settings.tuning.shortcuts[a] = nil
            }
            state.settings.tuning.shortcuts[action] = sc
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if recording { recording = false; Hotkeys.resume() }
    }
}

// MARK: Windows PC

struct WindowsTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Turn off when I use the PC") {
                Toggle("Turn off automatically when I start using the Windows PC", isOn: $state.settings.autoStopOnWindowsUse)
                if state.settings.autoStopOnWindowsUse {
                    Toggle("Count mouse movement (otherwise only keys, clicks and scrolling)", isOn: Binding(
                        get: { state.settings.tuning.autoStopMousePx > 0 },
                        set: { state.settings.tuning.autoStopMousePx = $0 ? 40 : 0 }))
                    if state.settings.tuning.autoStopMousePx > 0 {
                        LabeledContent("Mouse must move") {
                            HStack {
                                Slider(value: Binding(get: { Double(state.settings.tuning.autoStopMousePx) }, set: { state.settings.tuning.autoStopMousePx = Int($0) }),
                                       in: 10...400, step: 10)
                                Text("\(state.settings.tuning.autoStopMousePx) px").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                            }
                        }
                    }
                    Stepper(String(format: "Ignore input for %.1f s after turning on", state.settings.tuning.autoStopGraceSec),
                            value: $state.settings.tuning.autoStopGraceSec, in: 0...30, step: 0.5)
                }
                Note("Emergency stop on Windows, even on the lock screen: Ctrl+Alt+Shift+F12.")
            }
            .disabled(state.isOn)
            Section("Power while extending") {
                Toggle("Quiet fans (FanControl; still ramps up if it gets warm)", isOn: $state.settings.quietFans)
                Toggle("Low-power GPU (caps clocks; it only decodes video)", isOn: $state.settings.gpuLowPower)
                if state.settings.gpuLowPower {
                    LabeledContent("GPU clock limit") {
                        HStack {
                            Slider(value: Binding(get: { Double(state.settings.tuning.gpuCapMHz) }, set: { state.settings.tuning.gpuCapMHz = Int($0) }),
                                   in: 500...1900, step: 50)
                            Text("\(state.settings.tuning.gpuCapMHz) MHz").font(.caption.monospacedDigit()).frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
            .disabled(state.isOn)
            Section("Rest (sleep everything but PaneLink)") {
                Toggle(isOn: Binding(get: { state.restActive }, set: { state.setRest($0) })) {
                    Text("Rest now")
                    if let n = state.restNote { Text(n) }
                }
                .disabled(state.phase != .live)
                Toggle("Rest automatically whenever extending turns on", isOn: $state.settings.restOnStart)
                TextField("Also keep running (e.g. Discord, Spotify)", text: $state.settings.restKeep)
                Note("Pauses every app you have open on Windows (browsers, launchers, games) so the PC idles cool and quiet; they carry on exactly where they were when rest or extending ends, or when someone touches the PC. Windows itself, the desktop, drivers, FanControl and the ASUS/RGB tools keep running. Games with anti-cheat may refuse to pause and are left alone.")
            }
            Section("Waking and connecting") {
                Toggle("Wake the Windows PC when I turn extending on", isOn: $state.settings.wakeOnStart)
                TextField("PC network adapter (MAC)", text: $state.settings.wakeMAC)
                TextField("Windows address(es)", text: Binding(
                    get: { state.settings.hosts.joined(separator: ", ") },
                    set: { state.settings.hosts = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                    .onSubmit { state.reconnect() }
                Note("LAN address first; a Tailscale address can follow as a fallback for control.")
                if !state.settings.hosts.isEmpty {
                    LabeledContent("Paired PC") {
                        HStack {
                            Text(state.settings.pcName.isEmpty ? state.settings.hosts[0] : state.settings.pcName)
                            Button("Forget this PC…") { state.forgetPC() }
                        }
                    }
                }
            }
            .disabled(state.isOn)
        }
        .formStyle(.grouped)
    }
}
