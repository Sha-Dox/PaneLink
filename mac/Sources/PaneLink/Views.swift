import AppKit
import SwiftUI

// MARK: shared bits

struct StatusDot: View {
    @ObservedObject var state: AppState
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    var color: Color {
        switch state.phase {
        case .live: return .green
        case .starting: return .yellow
        case .error: return .red
        case .idle: return state.connectedHost == nil ? .gray : .blue
        }
    }
}

extension AppState {
    var phaseText: String {
        switch phase {
        case .idle:
            if let n = stopNote { return n }
            return connectedHost == nil ? connectionMessage : "Ready · \(connectedHost!)"
        case .starting: return "Starting…"
        case .live:
            let base = "Extending to \(stats.count) display\(stats.count == 1 ? "" : "s")"
            if connectedHost == nil { return base + " · reconnecting…" }
            if let h = streamHost, h != settings.hosts.first { return base + " · via \(h) (slower than LAN)" }
            if let r = lowPowerReason { return base + " · \(settings.tuning.lowPowerFps) fps (\(r))" }
            return base
        case let .error(m): return m
        }
    }
}

struct StatsLine: View {
    let s: StreamStats
    var body: some View {
        HStack(spacing: 10) {
            Label("\(Int(s.fps.rounded())) fps", systemImage: "speedometer")
            Label(String(format: "%.0f Mbps", s.mbps), systemImage: "arrow.up.right")
            Label(String(format: "%.1f ms", s.totalMs), systemImage: "timer")
            if s.lostFrames > 0 { Label("\(s.lostFrames) lost (10 s)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

// MARK: menu bar

struct MenuBarView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PaneLink").font(.headline)
                    HStack(spacing: 6) {
                        StatusDot(state: state)
                        Text(state.phaseText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { state.isOn }, set: { $0 ? state.start() : state.stop() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!state.isOn && (state.needsSetup || (state.connectedHost == nil && !state.canWake)))
            }

            if state.needsSetup {
                Button { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) } label: {
                    Label(state.settings.hosts.isEmpty ? "Set up your Windows PC…" : "Pair with your Windows PC…", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
            }
            if state.settings.quietFans && !state.fansReady && !state.needsSetup { FanReminder() }
            if state.settings.wakeOnStart && !state.settings.wakeFromOffReady && state.canWake && !state.needsSetup { WakeReminder(state: state) }

            if state.settings.tuning.menu.lowPower {
            Toggle(isOn: $state.settings.lowPowerManual) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Low power (\(state.settings.tuning.lowPowerFps) fps)")
                    if !state.settings.lowPowerManual, state.lowPowerActive, let r = state.lowPowerReason {
                        Text("Active automatically: \(r)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            }

            if state.settings.tuning.menu.statsOverlay {
                Toggle("Stats overlay on the Windows displays", isOn: $state.settings.statsOverlay)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if state.settings.tuning.menu.rest && state.phase == .live {
                Toggle(isOn: Binding(get: { state.restActive }, set: { state.setRest($0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Rest Windows PC (pause its other apps)")
                        if let n = state.restNote { Text(n).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if state.settings.tuning.menu.wake && state.connectedHost == nil && !state.isOn && WakeOnLAN.parseMAC(state.settings.wakeMAC) != nil {
                Button { state.wake(); state.reconnect() } label: { Label("Wake Windows PC", systemImage: "power") }
            }

            if state.settings.tuning.menu.monitors && !state.monitors.isEmpty {
                Divider()
                ForEach(state.monitors) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: m.width < m.height ? "rectangle.portrait" : "rectangle")
                            Text(m.name).font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(m.width)×\(m.height) · \(m.refreshRate) Hz").font(.caption).foregroundStyle(.secondary)
                        }
                        if let s = state.stats[m.device] { StatsLine(s: s) }
                    }
                    .opacity(state.prefs(for: m).enabled ? 1 : 0.4)
                }
            }

            Divider()
            HStack {
                if state.settings.tuning.menu.testPattern {
                    Button("Test pattern") { state.toggleTestPattern() }.disabled(state.phase != .live)
                }
                Button("Open PaneLink…") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { state.stop(); NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct MonitorRow: View {
    @ObservedObject var state: AppState
    let monitor: RemoteMonitor

    var body: some View {
        let p = state.prefs(for: monitor)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: Binding(get: { p.enabled }, set: { var q = p; q.enabled = $0; state.setPrefs(q, for: monitor) })) {
                    HStack(spacing: 8) {
                        Image(systemName: monitor.width < monitor.height ? "rectangle.portrait" : "rectangle")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(monitor.name).font(.body.weight(.medium))
                            Text("\(monitor.width)×\(monitor.height) · \(monitor.refreshRate) Hz\(monitor.primary ? " · primary on Windows" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(state.isOn)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(p.bitrateMbps) Mbps").font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { Double(p.bitrateMbps) }, set: { var q = p; q.bitrateMbps = Int($0); state.setPrefs(q, for: monitor) }),
                           in: 10...300, step: 5)
                        .frame(width: 160)
                }
            }
            if let s = state.stats[monitor.device] {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 2) {
                    GridRow {
                        stat("Frame rate", "\(Int(s.fps.rounded())) fps")
                        stat("Bitrate", String(format: "%.1f Mbps", s.mbps))
                        stat("Encode", String(format: "%.1f ms", s.encodeMs))
                        stat("Network", String(format: "%.1f ms", s.networkMs))
                        stat("Decode+show", String(format: "%.1f ms", s.displayMs))
                        stat("Total", String(format: "%.1f ms", s.totalMs))
                        stat("Lost (10 s)", "\(s.lostFrames)")
                    }
                }
                .padding(.leading, 30)
            }
        }
            SharpnessPicker(state: state, monitor: monitor).padding(.leading, 30)
            CoveredArea(state: state, monitor: monitor).padding(.leading, 30)
            ColorPanel(state: state, monitor: monitor).padding(.leading, 30)
        .padding(.vertical, 4)
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.callout.monospacedDigit().weight(.medium))
        }
    }
}

/// Live picture adjustments for one Windows monitor (applied on the Windows GPU as you drag).
struct ColorPanel: View {
    @ObservedObject var state: AppState
    let monitor: RemoteMonitor
    @State private var open = false

    var body: some View {
        let p = state.prefs(for: monitor)
        let c = p.color
        func bind(_ kp: WritableKeyPath<ColorSettings, Double>) -> Binding<Double> {
            Binding(get: { state.prefs(for: monitor).color[keyPath: kp] },
                    set: { var q = state.prefs(for: monitor); q.color[keyPath: kp] = $0; state.setPrefs(q, for: monitor) })
        }
        return DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Preset", selection: Binding(
                    get: { c.preset },
                    set: { preset in
                        guard let v = preset.settings else { return }
                        var q = state.prefs(for: monitor); q.color = v; state.setPrefs(q, for: monitor)
                    })) {
                    ForEach(ColorSettings.Preset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                UserPresets(state: state, monitor: monitor)
                slider("Brightness", bind(\.brightness), -0.3...0.3, format: { String(format: "%+.0f", $0 * 100) })
                slider("Contrast", bind(\.contrast), 0.5...1.5, format: { String(format: "%.0f%%", $0 * 100) })
                slider("Saturation", bind(\.saturation), 0...2, format: { String(format: "%.0f%%", $0 * 100) })
                slider("Gamma", bind(\.gamma), 0.6...1.6, format: { String(format: "%.2f", $0) })
                slider("Temperature", bind(\.temperature), -1...1, format: { $0 == 0 ? "neutral" : String(format: $0 > 0 ? "warm %.0f" : "cool %.0f", abs($0) * 100) })
                HStack {
                    Text(state.isOn ? "Changes apply instantly." : "Applies when extending is on.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { var q = state.prefs(for: monitor); q.color = ColorSettings(); state.setPrefs(q, for: monitor) }
                        .disabled(c == ColorSettings())
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paintpalette")
                Text("Color").font(.callout)
                Text(state.presetName(for: c)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func slider(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: v, in: range)
            Text(format(v.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
        }
    }
}

// MARK: cursor alignment

struct AlignmentSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var aligner = CursorAligner.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Line the cursor up physically across displays of different sizes (like LittleBigMouse)",
                       isOn: $state.settings.cursorAlign)
                if state.settings.cursorAlign && !aligner.trusted {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Needs Accessibility permission to move the cursor.").font(.callout)
                        Spacer()
                        Button("Grant Access…") { aligner.requestAccess() }
                    }
                }
                if aligner.links.isEmpty {
                    Text(state.isOn ? "No displays share an edge." : "Turn on extending to align the Windows displays.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(aligner.links) { l in
                        HStack {
                            Image(systemName: l.vertical ? "rectangle.split.2x1" : "rectangle.split.1x2").foregroundStyle(.secondary)
                            Text(l.title).lineLimit(1)
                            if state.settings.edgeNotches[l.id] == nil {
                                Text("physical size").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Align…") {
                                AlignOverlay.show(l) { state.saveAlignment($0) }
                            }
                            Button("Reset") { state.resetAlignment(l) }
                                .disabled(state.settings.edgeNotches[l.id] == nil)
                        }
                    }
                    Text("Align… shows notches ① and ② on both sides of the edge. Drag each pair until the lines meet across the bezel; the cursor and dragged windows then cross where they physically should.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: { Text("Cursor alignment").font(.headline) }
    }
}

/// Shown until the Windows agent reports that the quiet-fan profiles are in place.
/// Until turning on from a full shutdown has worked once (or the user dismisses it).
struct WakeReminder: View {
    @ObservedObject var state: AppState
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "power").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Turning the PC on from shutdown isn't set up").font(.callout.weight(.semibold))
                Text("In the PC's BIOS turn off ErP / deep sleep and turn on wake by PCI-E / network (ASUS: Advanced → APM Configuration), and Windows Fast Startup off. Waking from sleep already works.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("I did it") { state.settings.wakeFromOffReady = true }.controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

struct FanReminder: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "fan.badge.automatic").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quiet fans aren't set up on Windows yet").font(.callout.weight(.semibold))
                Text("Put fans-quiet.cmd and fans-normal.cmd in C:\\ProgramData\\PaneLink on the PC (see the README), or turn off \"Quiet fans\" in Windows PC settings to hide this.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

/// Named color presets of your own, shared by all monitors.
struct UserPresets: View {
    @ObservedObject var state: AppState
    let monitor: RemoteMonitor
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        HStack {
            Menu("My presets") {
                let names = state.settings.tuning.colorPresets.keys.sorted()
                if names.isEmpty { Text("None saved yet") }
                ForEach(names, id: \.self) { n in
                    Button(n) {
                        guard let v = state.settings.tuning.colorPresets[n] else { return }
                        var q = state.prefs(for: monitor); q.color = v; state.setPrefs(q, for: monitor)
                    }
                }
                if !names.isEmpty {
                    Divider()
                    Menu("Delete") {
                        ForEach(names, id: \.self) { n in Button(n) { state.settings.tuning.colorPresets[n] = nil } }
                    }
                }
            }
            .fixedSize()
            if naming {
                TextField("Name", text: $name).frame(width: 140).onSubmit(save)
                Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { naming = false }
            } else {
                Button("Save current as preset…") { name = ""; naming = true }
            }
            Spacer()
            Menu("Copy to") {
                ForEach(state.monitors.filter { $0 != monitor }) { m in
                    Button(m.name) { var q = state.prefs(for: m); q.color = state.prefs(for: monitor).color; state.setPrefs(q, for: m) }
                }
            }
            .fixedSize()
            .disabled(state.monitors.count < 2)
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        state.settings.tuning.colorPresets[n] = state.prefs(for: monitor).color
        naming = false
    }
}

/// HiDPI (2× render, scaled to the monitor = sharp text) and the "looks like" size. Applies on the next start.
/// "My laptop is in front of part of this monitor": keep that strip black and make the Mac display
/// only the visible part, so nothing (windows, the cursor) ends up behind the laptop.
struct CoveredArea: View {
    @ObservedObject var state: AppState
    let monitor: RemoteMonitor
    @State private var open = false

    var body: some View {
        let c = state.prefs(for: monitor).covered
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 4) {
                edge("Bottom", \.bottom, monitor.height)
                edge("Top", \.top, monitor.height)
                edge("Left", \.left, monitor.width)
                edge("Right", \.right, monitor.width)
                HStack {
                    let (w, h) = monitor.visibleSize(c)
                    Text("Mac sees \(w)×\(h)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !c.isEmpty { Button("Reset") { set { $0 = Insets() } } }
                    if state.isOn {
                        Button("Apply now") { state.stop(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { state.start() } }
                            .help("Turns extending off and on again with the new area")
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Label(c.isEmpty ? "Part of this monitor is covered…" : "Covered area: \(summary(c))", systemImage: "laptopcomputer")
        }
        .font(.callout)
    }

    private func summary(_ c: Insets) -> String {
        [("bottom", c.bottom), ("top", c.top), ("left", c.left), ("right", c.right)].filter { $0.1 > 0 }.map { "\($0.0) \($0.1) px" }.joined(separator: ", ")
    }

    private func set(_ f: (inout Insets) -> Void) {
        var p = state.prefs(for: monitor); f(&p.covered); state.setPrefs(p, for: monitor)
    }

    private func edge(_ name: String, _ k: WritableKeyPath<Insets, Int>, _ full: Int) -> some View {
        let v = state.prefs(for: monitor).covered[keyPath: k]
        return HStack {
            Text(name).frame(width: 50, alignment: .leading)
            Slider(value: Binding(get: { Double(v) }, set: { n in set { $0[keyPath: k] = Int(n / 10) * 10 } }), in: 0...Double(full / 2))
            Stepper("", value: Binding(get: { v }, set: { n in set { $0[keyPath: k] = min(max(0, n), full / 2) } }), step: 10).labelsHidden()
            Text("\(v) px").font(.caption.monospacedDigit()).frame(width: 56, alignment: .trailing)
        }
    }
}

struct SharpnessPicker: View {
    @ObservedObject var state: AppState
    let monitor: RemoteMonitor

    private var options: [(String, Bool, Double)] {
        let w = Double(monitor.width), h = Double(monitor.height)
        func size(_ f: Double) -> String { "\(Int((w * f / 2).rounded()) * 2)×\(Int((h * f / 2).rounded()) * 2)" }
        return [("Sharp (HiDPI) · \(size(1))", true, 1.0),
                ("Sharp, larger text · looks like \(size(0.875))", true, 0.875),
                ("Sharp, larger text · looks like \(size(0.8))", true, 0.8),
                ("Sharp, largest text · looks like \(size(0.75))", true, 0.75),
                ("Standard (1×, lightest on battery) · \(size(1))", false, 1.0)]
    }

    var body: some View {
        let p = state.prefs(for: monitor)
        HStack {
            Image(systemName: "textformat.size").foregroundStyle(.secondary)
            Picker("Sharpness", selection: Binding(
                get: { options.firstIndex { $0.1 == p.hiDPI && abs($0.2 - (p.hiDPI ? p.uiScale : 1)) < 0.01 } ?? 0 },
                set: { i in var q = state.prefs(for: monitor); q.hiDPI = options[i].1; q.uiScale = options[i].2; state.setPrefs(q, for: monitor) })) {
                ForEach(options.indices, id: \.self) { Text(options[$0].0).tag($0) }
            }
            .fixedSize()
            if state.isOn {
                Button("Apply now") { state.stop(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { state.start() } }
                    .help("Turns extending off and on again with the new setting")
            }
        }
        .font(.callout)
    }
}
