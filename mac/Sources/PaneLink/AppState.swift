import AppKit
import Combine
import Foundation
import ServiceManagement

struct MonitorPrefs: Codable, Equatable {
    var enabled = true
    var bitrateMbps: Int
    var color = ColorSettings()
    var hiDPI = true          // render at 2× and scale down to the monitor (sharp text, like BetterDisplay)
    var uiScale = 1.0         // "looks like" size as a fraction of native (smaller = bigger text)
    var covered = Insets()    // part of the panel hidden behind the laptop: kept black, the Mac display is the rest

    init(bitrateMbps: Int) { self.bitrateMbps = bitrateMbps }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        bitrateMbps = (try? c.decode(Int.self, forKey: .bitrateMbps)) ?? 60
        color = (try? c.decode(ColorSettings.self, forKey: .color)) ?? ColorSettings()
        hiDPI = (try? c.decode(Bool.self, forKey: .hiDPI)) ?? true
        uiScale = (try? c.decode(Double.self, forKey: .uiScale)) ?? 1
        covered = (try? c.decode(Insets.self, forKey: .covered)) ?? Insets()
    }
}

/// Where a Windows display sits, relative to the Mac's own screen (top-left, in points), plus its size
/// then, so a display that changes size (sharpness, covered area) keeps the edge it shares with the Mac.
struct LayoutPos: Codable, Equatable { var x, y, w, h: Double }

/// Windows pixels per edge of a monitor that the picture stays out of.
struct Insets: Codable, Equatable {
    var left = 0, top = 0, right = 0, bottom = 0
    var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
}

extension RemoteMonitor {
    /// The part of the panel we stream to (even sizes for the encoder).
    func visibleSize(_ c: Insets) -> (Int, Int) {
        let w = max(320, width - c.left - c.right) & ~1, h = max(320, height - c.top - c.bottom) & ~1
        return (w, h)
    }
}

struct Settings: Codable, Equatable {
    var hosts: [String] = []                          // LAN first, e.g. a Tailscale address as fallback
    var pcName = ""                                   // the paired PC (from discovery)
    var token = ""                                    // from pairing; sent as AUTH on every connection
    var codec: Encoder.Codec = .hevc
    var vsync = true                                  // tear-free presenting on Windows (one-frame queue)
    var fecGroup = 8                                  // 1 parity per 8 packets (12.5%)
    var disableAWDL = true                            // keep Wi-Fi on-channel (awdl0/llw0 down)
    var monitors: [String: MonitorPrefs] = [:]
    var arranged: Set<UInt32> = []                    // virtual displays we've placed once already
    var layout: [String: LayoutPos] = [:]             // our own copy of the arrangement, per display serial
    var lowPowerManual = false                        // menu bar toggle: always 60 fps
    var lowPowerAuto = true                           // 60 fps on battery below the threshold / macOS Low Power Mode
    var lowPowerThreshold = 20
    var fullRange = false                             // full-range (0-255) YUV: deeper blacks
    var keepMacMain = true                            // never let a Windows display become the main display
    var autoStopOnWindowsUse = true                   // turn off when someone uses the Windows keyboard/mouse
    var cursorAlign = true                            // LittleBigMouse-style edge alignment
    var edgeNotches: [String: EdgeNotches] = [:]      // per shared edge, see CursorAligner
    var restoreWindows = true                         // put windows back on the Windows displays when re-enabled
    var restoreMinutes = 10                           // ...if extending comes back within this long
    var quietFans = false                             // Windows runs fans-quiet.cmd while extending (e.g. a FanControl profile)
    var gpuLowPower = true                            // Windows caps the GPU clocks while extending (it only decodes video)
    var wakeMAC = ""                                  // Windows PC's wired adapter (Wake-on-LAN; filled in by pairing)
    var wakeOnStart = true                            // turning extending on wakes the PC if it's asleep
    var restOnStart = false                           // put the PC's other apps to sleep whenever extending turns on
    var restKeep = ""                                 // extra Windows apps rest leaves running (comma-separated)
    var wakeFromOffReady = false                      // BIOS set up for waking from a full shutdown (or the user said so)
    var statsOverlay = false                          // live stats in the corner of each Windows display
    var hotkeys = true                                // global shortcuts (see tuning.shortcuts)
    var tuning = Tuning()

    init() {}

    // Tolerant decoding: missing keys (new settings) keep their defaults instead of resetting everything.
    private enum CodingKeys: String, CodingKey { case hosts, pcName, token, codec, vsync = "tearFree", fecGroup, wifiOnChannel, monitors, arranged, layout, lowPowerManual, lowPowerAuto, lowPowerThreshold, fullRange, keepMacMain, autoStopOnWindowsUse, cursorAlign, edgeNotches, restoreWindows, restoreMinutes, quietFans, gpuLowPower, wakeMAC, wakeOnStart, restOnStart, restKeep, wakeFromOffReady, statsOverlay, hotkeys, tuning }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        hosts = (try? c.decode([String].self, forKey: .hosts)) ?? hosts
        pcName = (try? c.decode(String.self, forKey: .pcName)) ?? pcName
        token = (try? c.decode(String.self, forKey: .token)) ?? token
        codec = (try? c.decode(Encoder.Codec.self, forKey: .codec)) ?? codec
        vsync = (try? c.decode(Bool.self, forKey: .vsync)) ?? vsync
        fecGroup = (try? c.decode(Int.self, forKey: .fecGroup)) ?? fecGroup
        disableAWDL = (try? c.decode(Bool.self, forKey: .wifiOnChannel)) ?? disableAWDL
        monitors = (try? c.decode([String: MonitorPrefs].self, forKey: .monitors)) ?? monitors
        arranged = (try? c.decode(Set<UInt32>.self, forKey: .arranged)) ?? arranged
        layout = (try? c.decode([String: LayoutPos].self, forKey: .layout)) ?? layout
        lowPowerManual = (try? c.decode(Bool.self, forKey: .lowPowerManual)) ?? lowPowerManual
        lowPowerAuto = (try? c.decode(Bool.self, forKey: .lowPowerAuto)) ?? lowPowerAuto
        lowPowerThreshold = (try? c.decode(Int.self, forKey: .lowPowerThreshold)) ?? lowPowerThreshold
        fullRange = (try? c.decode(Bool.self, forKey: .fullRange)) ?? fullRange
        keepMacMain = (try? c.decode(Bool.self, forKey: .keepMacMain)) ?? keepMacMain
        autoStopOnWindowsUse = (try? c.decode(Bool.self, forKey: .autoStopOnWindowsUse)) ?? autoStopOnWindowsUse
        cursorAlign = (try? c.decode(Bool.self, forKey: .cursorAlign)) ?? cursorAlign
        edgeNotches = (try? c.decode([String: EdgeNotches].self, forKey: .edgeNotches)) ?? edgeNotches
        restoreWindows = (try? c.decode(Bool.self, forKey: .restoreWindows)) ?? restoreWindows
        restoreMinutes = (try? c.decode(Int.self, forKey: .restoreMinutes)) ?? restoreMinutes
        quietFans = (try? c.decode(Bool.self, forKey: .quietFans)) ?? quietFans
        gpuLowPower = (try? c.decode(Bool.self, forKey: .gpuLowPower)) ?? gpuLowPower
        wakeMAC = (try? c.decode(String.self, forKey: .wakeMAC)) ?? wakeMAC
        wakeOnStart = (try? c.decode(Bool.self, forKey: .wakeOnStart)) ?? wakeOnStart
        restOnStart = (try? c.decode(Bool.self, forKey: .restOnStart)) ?? restOnStart
        restKeep = (try? c.decode(String.self, forKey: .restKeep)) ?? restKeep
        wakeFromOffReady = (try? c.decode(Bool.self, forKey: .wakeFromOffReady)) ?? wakeFromOffReady
        statsOverlay = (try? c.decode(Bool.self, forKey: .statsOverlay)) ?? statsOverlay
        hotkeys = (try? c.decode(Bool.self, forKey: .hotkeys)) ?? hotkeys
        tuning = (try? c.decode(Tuning.self, forKey: .tuning)) ?? tuning
    }
    func encode(to e: Swift.Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(hosts, forKey: .hosts); try c.encode(pcName, forKey: .pcName); try c.encode(token, forKey: .token)
        try c.encode(codec, forKey: .codec); try c.encode(vsync, forKey: .vsync)
        try c.encode(fecGroup, forKey: .fecGroup); try c.encode(disableAWDL, forKey: .wifiOnChannel)
        try c.encode(monitors, forKey: .monitors); try c.encode(arranged, forKey: .arranged); try c.encode(layout, forKey: .layout)
        try c.encode(lowPowerManual, forKey: .lowPowerManual); try c.encode(lowPowerAuto, forKey: .lowPowerAuto)
        try c.encode(lowPowerThreshold, forKey: .lowPowerThreshold); try c.encode(fullRange, forKey: .fullRange)
        try c.encode(keepMacMain, forKey: .keepMacMain); try c.encode(autoStopOnWindowsUse, forKey: .autoStopOnWindowsUse)
        try c.encode(cursorAlign, forKey: .cursorAlign); try c.encode(edgeNotches, forKey: .edgeNotches)
        try c.encode(restoreWindows, forKey: .restoreWindows); try c.encode(restoreMinutes, forKey: .restoreMinutes)
        try c.encode(quietFans, forKey: .quietFans); try c.encode(gpuLowPower, forKey: .gpuLowPower)
        try c.encode(wakeMAC, forKey: .wakeMAC); try c.encode(wakeOnStart, forKey: .wakeOnStart)
        try c.encode(restOnStart, forKey: .restOnStart); try c.encode(restKeep, forKey: .restKeep)
        try c.encode(wakeFromOffReady, forKey: .wakeFromOffReady)
        try c.encode(statsOverlay, forKey: .statsOverlay); try c.encode(hotkeys, forKey: .hotkeys)
        try c.encode(tuning, forKey: .tuning)
    }

    static func defaultBitrate(for m: RemoteMonitor) -> Int {
        let mpx = Double(m.width * m.height) / 1e6
        return Int((mpx * Double(m.refreshRate) / 7).rounded())  // 1440p144 -> 76 Mbps
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable { case idle, starting, live, error(String) }

    @Published var phase: Phase = .idle
    @Published var connectedHost: String?
    @Published var streamHost: String?
    @Published var stopNote: String?      // why extending last turned itself off   // where the video is actually going
    @Published var connectionMessage = "Looking for Windows…"
    @Published var restActive = false    // Windows' other apps are paused (see AgentClient.rest)
    @Published var restNote: String?
    @Published var fansReady = false     // the agent says the quiet-fan profiles exist (older agents never say)
    @Published var monitors: [RemoteMonitor] = []
    enum Pairing: Equatable { case none, needed, codeShown, failed(String) }
    @Published var pairing: Pairing = .none
    @Published var discovered: [Discovery.PC] = []
    @Published var scanning = false
    @Published var screenAccess = CGPreflightScreenCaptureAccess()
    /// Not set up yet, the PC doesn't know this Mac, or no Screen Recording permission: the setup card shows.
    var needsSetup: Bool { settings.hosts.isEmpty || pairing != .none || !screenAccess }
    var isFirstRun: Bool { settings.hosts.isEmpty }

    /// While the setup card is up: notice the permission being granted in System Settings.
    func refreshPermissions() { screenAccess = CGPreflightScreenCaptureAccess() }
    @Published var stats: [String: StreamStats] = [:]   // per monitor device
    @Published var settings: Settings {
        didSet {
            save()
            if settings.lowPowerManual != oldValue.lowPowerManual || settings.lowPowerAuto != oldValue.lowPowerAuto
                || settings.lowPowerThreshold != oldValue.lowPowerThreshold { applyPowerPolicy() }
            if settings.cursorAlign != oldValue.cursorAlign || settings.edgeNotches != oldValue.edgeNotches { CursorAligner.shared.rebuild() }
            if settings.statsOverlay != oldValue.statsOverlay || settings.tuning.overlay != oldValue.tuning.overlay { applyStatsOverlay() }
            if settings.hotkeys != oldValue.hotkeys || settings.tuning.shortcuts != oldValue.tuning.shortcuts { Hotkeys.setEnabled(settings.hotkeys) }
            if settings.tuning.lowPowerFps != oldValue.tuning.lowPowerFps || settings.tuning.stallMs != oldValue.tuning.stallMs {
                for s in sessions.values { s.setTuning(lowPowerFps: settings.tuning.lowPowerFps, stallMs: settings.tuning.stallMs) }
            }
        }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var power = PowerMonitor.State()
    private let powerMonitor = PowerMonitor()

    /// 60 fps when toggled on, or automatically on battery at/below the threshold or in macOS Low Power Mode.
    var lowPowerActive: Bool {
        if settings.lowPowerManual { return true }
        guard settings.lowPowerAuto, power.onBattery else { return false }
        return power.percent <= settings.lowPowerThreshold || power.lowPowerMode
    }

    var lowPowerReason: String? {
        guard lowPowerActive else { return nil }
        if settings.lowPowerManual { return "Low power on" }
        return power.lowPowerMode ? "macOS Low Power Mode" : "Battery \(power.percent)%"
    }

    private func applyPowerPolicy() {
        let on = lowPowerActive
        for s in sessions.values { s.setLowPower(on) }
    }

    var isOn: Bool { phase == .starting || phase == .live }

    private let client = AgentClient()
    private var sessions: [String: StreamSession] = [:]
    private var screens: [String: VirtualScreen] = [:]
    private var statsTimer: Timer?
    private var reconnectTimer: Timer?
    private var graceTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var liveStarts: [(RemoteMonitor, UInt16)] = []
    private var activity: NSObjectProtocol?

    private init() {
        if let d = UserDefaults.standard.data(forKey: "settings"), let s = try? JSONDecoder().decode(Settings.self, from: d) {
            settings = s
        } else {
            settings = Settings()
        }
        client.onEvent = { [weak self] e in Task { @MainActor in self?.handle(e) } }
        power = powerMonitor.state
        powerMonitor.onChange = { [weak self] st in
            Task { @MainActor in self?.power = st; self?.applyPowerPolicy() }
        }
        if !CommandLine.arguments.contains(where: { ["--aligntest", "--windowtest", "--dummywindow", "--overlaytest", "--waketest", "--hotkeytest", "--stalltest", "--hidpitest", "--pipetest"].contains($0) }) { client.connect(hosts: settings.hosts, token: settings.token) }
        autostart = CommandLine.arguments.contains("--autostart")
        if settings.hosts.isEmpty { connectionMessage = "No Windows PC set up"; DispatchQueue.main.async { self.scan() } }
        if settings.hotkeys && !CommandLine.arguments.contains(where: { $0.hasSuffix("test") || $0 == "--dummywindow" }) {
            DispatchQueue.main.async { Hotkeys.setEnabled(true) }
        }
        Log.write("launch \(CommandLine.arguments)")
    }

    private var autostart = false

    private func save() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    func prefs(for m: RemoteMonitor) -> MonitorPrefs {
        settings.monitors[m.device] ?? MonitorPrefs(bitrateMbps: Settings.defaultBitrate(for: m))
    }

    func setPrefs(_ p: MonitorPrefs, for m: RemoteMonitor) {
        settings.monitors[m.device] = p
        sessions[m.device]?.encoder.setBitrate(mbps: p.bitrateMbps)
        sessions[m.device]?.setColor(p.color)
    }

    func reconnect() {
        connectionMessage = "Connecting…"
        if !CommandLine.arguments.contains(where: { ["--aligntest", "--windowtest", "--dummywindow", "--overlaytest", "--waketest", "--hotkeytest", "--stalltest", "--hidpitest", "--pipetest"].contains($0) }) { client.connect(hosts: settings.hosts, token: settings.token) }
    }

    // MARK: control channel

    private func handle(_ e: AgentClient.Event) {
        switch e {
        case let .connected(host):
            connectedHost = host
            connectionMessage = "Connected to \(host)"
            if pendingPairCode { pendingPairCode = false; showPairCode() }
            reconnectTimer?.invalidate()
            if phase == .live {
                // Seamless resume: video never stopped; the agent treats identical STARTs as no-ops.
                graceTimer?.invalidate()
                Log.write("control link back (\(host)); resuming")
                for (m, port) in liveStarts {
                    client.start(index: m.index, width: m.width, height: m.height, hz: streamRate(for: m),
                                 codec: settings.codec, port: port, vsync: settings.vsync, autoStop: settings.autoStopOnWindowsUse, quietFans: settings.quietFans, gpuLowPower: settings.gpuLowPower, tuning: settings.tuning, covered: prefs(for: m).covered)
                }
            }
        case let .monitors(list):
            if phase == .live { return }   // keep the layout stable while extending
            monitors = list.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
            if autostart { autostart = false; start(); return }
            if phase == .starting { Task { await self.startStreams() } }
        case let .error(idx, msg) where idx < 0 && msg.hasPrefix("rest"):
            restActive = false; restNote = msg
        case let .error(idx, msg):
            phase = .error("Windows: monitor \(idx): \(msg)")
        case .ok: break
        case let .fansReady(r): fansReady = r
        case .needsPairing:
            if pairing == .none || pairing == .needed {
                pairing = .needed
                connectionMessage = "Not paired with \(settings.pcName.isEmpty ? "this PC" : settings.pcName) yet"
            }
        case .pairing: pairing = .codeShown
        case let .paired(token):
            settings.token = token
            pairing = .none
            Log.write("paired with \(connectedHost ?? "?")")
            client.authenticate(token)
            connectionMessage = "Connected to \(connectedHost ?? "")"
            if settings.wakeMAC.isEmpty || settings.pcName.isEmpty {   // paired by address: learn name + MAC for wake-up
                let host = connectedHost
                Task {
                    if let pc = await Discovery.scan().first(where: { $0.host == host }) {
                        if settings.wakeMAC.isEmpty { settings.wakeMAC = pc.mac }
                        if settings.pcName.isEmpty { settings.pcName = pc.name }
                    }
                }
            }
        case let .pairFailed(why):
            pairing = .failed(why == "wrong" ? "That code didn't match. Try again."
                              : why == "wait" ? "Wait a few seconds, then try again." : "The code expired. Show a new one.")
        case let .rest(on, paused, running):
            restActive = on
            restNote = on ? "\(paused) app(s) asleep" + (running > 0 ? ", \(running) protected (still running)" : "") : nil
            Log.write("rest: \(on ? "on" : "off") \(paused) paused \(running) protected")
        case let .stoppedByRemote(why):
            Log.write("Windows stopped extending (\(why))")
            stop()
            stopNote = why == "activity" ? "Turned off: the Windows PC is being used" : "Turned off from Windows (Ctrl+Alt+Shift+F12)"
        case let .disconnected(reason):
            connectedHost = nil
            connectionMessage = reason ?? "Disconnected"
            if phase == .live {
                // Don't tear anything down: UDP video keeps flowing and Windows keeps the viewers up
                // for 15 s. Reconnect fast; only give up if the link stays down.
                Log.write("control link lost (\(reason ?? "-")); reconnecting, displays kept")
                connectionMessage = "Reconnecting…"
                if graceTimer == nil || !graceTimer!.isValid {
                    graceTimer = Timer.scheduledTimer(withTimeInterval: 14, repeats: false) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.connectedHost == nil, self.phase == .live else { return }
                            self.teardown()
                            self.phase = .error("Lost connection to Windows")
                        }
                    }
                }
                scheduleReconnect(after: 0.5)
                return
            }
            if phase == .starting, let until = wakeUntil, Date() < until {
                // still waking up: keep knocking (the NIC sometimes misses the first packet while entering sleep)
                connectionMessage = "Turning on Windows… \(Int(Date().timeIntervalSince(wakeStarted ?? Date()))) s"
                WakeOnLAN.send(mac: settings.wakeMAC, hosts: settings.hosts)
                scheduleReconnect(after: 2)
                return
            }
            if isOn { teardown(); phase = .error(wakeUntil != nil ? "Windows didn't turn on (from a full shutdown the BIOS needs ErP off + Power On By PCI-E on)" : "Lost connection to Windows") }
            wakeUntil = nil
            scheduleReconnect()
        }
    }

    private func scheduleReconnect(after delay: TimeInterval = 3) {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.client.connect(hosts: self?.settings.hosts ?? [], token: self?.settings.token ?? "") }
        }
    }

    // MARK: on / off

    func toggle() { isOn ? stop() : start() }

    /// Puts every other app on the Windows PC to sleep (or wakes them). Only while extending.
    func setRest(_ on: Bool) {
        guard phase == .live || !on else { return }
        restActive = on
        client.rest(on, keep: settings.restKeep)
    }

    // MARK: setup / pairing

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let found = await Discovery.scan()
            discovered = found
            scanning = false
        }
    }

    /// Picks a PC (from discovery or typed in) and asks it to show a pairing code.
    func pair(with host: String, name: String = "", mac: String = "") {
        settings.hosts = [host] + settings.hosts.filter { $0 != host }
        if !name.isEmpty { settings.pcName = name }
        if !mac.isEmpty { settings.wakeMAC = mac }
        settings.token = ""
        pairing = .needed
        if client.isConnected && connectedHost == host { showPairCode() } else {
            pendingPairCode = true
            client.connect(hosts: [host], token: "")
        }
    }

    private var pendingPairCode = false

    func showPairCode() {
        pairing = .codeShown
        client.pair(name: Host.current().localizedName ?? "Mac")
    }

    func submit(code: String) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { pairing = .failed("The code has 6 digits."); return }
        client.submit(code: digits)
    }

    /// Forgets the PC on this Mac (the PC keeps its token until its paired.txt is deleted).
    func forgetPC() {
        stop()
        client.disconnect()
        settings.hosts = []; settings.token = ""; settings.pcName = ""; settings.wakeMAC = ""
        connectedHost = nil
        monitors = []
        pairing = .none
        connectionMessage = "No Windows PC set up"
        scan()
    }

    func start() {
        guard !isOn else { return }
        refreshPermissions()
        if needsSetup { phase = .error("Finish setting up first (Open PaneLink…)"); return }
        stopNote = nil
        phase = .starting
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        // Refresh the monitor list (the reply triggers startStreams). Always prefer the first (LAN)
        // address for video: if we're on the Tailscale fallback, retry the LAN first.
        if client.isConnected && connectedHost == settings.hosts.first { client.send("HELLO 1") }
        else {
            if connectedHost == nil && canWake { wake() }
            reconnect()
        }
    }

    var canWake: Bool { settings.wakeOnStart && WakeOnLAN.parseMAC(settings.wakeMAC) != nil }
    private var wakeUntil: Date?
    private var wakeStarted: Date?

    /// Sends the magic packet and keeps knocking until the agent answers: up to 3 minutes, enough for a
    /// cold boot from a full shutdown (POST + Windows + the PaneLink service, no sign-in needed).
    func wake() {
        WakeOnLAN.send(mac: settings.wakeMAC, hosts: settings.hosts)
        wakeUntil = Date().addingTimeInterval(180)
        wakeStarted = Date()
        connectionMessage = "Turning on Windows…"
    }

    func stop() {
        wakeUntil = nil
        client.stopAll()
        teardown()
        phase = .idle
    }

    private func teardown() {
        graceTimer?.invalidate()
        liveStarts.removeAll()
        restActive = false; restNote = nil   // Windows wakes its apps itself when the viewers go
        streamHost = nil
        TestPattern.hide()
        StatsOverlay.hide()
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        if phase == .live && !layoutLocked { saveLayout() }
        layoutSaveTimer?.invalidate()
        if settings.restoreWindows && phase == .live {
            var ids: [CGDirectDisplayID: UInt32] = [:]
            for m in monitors { if let sc = screens[m.device] { ids[sc.displayID] = m.serial } }
            WindowMemory.capture(displays: ids)
        }
        screens.removeAll()   // releasing CGVirtualDisplay removes the display
        stats.removeAll()
        statsTimer?.invalidate()
        statsTimer = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        WiFiTuner.end()
    }

    private func startStreams() async {
        guard phase == .starting, let host = connectedHost else { return }
        streamHost = host
        let enabled = monitors.filter { prefs(for: $0).enabled }
        guard !enabled.isEmpty else { phase = .error("No monitors enabled"); return }

        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                                                         reason: "Streaming displays")
        if settings.disableAWDL { WiFiTuner.begin() }

        for m in enabled {
            let p = prefs(for: m)
            let (vw, vh) = m.visibleSize(p.covered)
            guard let screen = VirtualScreen(name: "\(m.name) (Windows)", width: vw, height: vh,
                                             refreshRate: Double(streamRate(for: m)), serial: m.serial,
                                             hiDPI: p.hiDPI, uiScale: p.uiScale) else {
                phase = .error("Couldn't create virtual display for \(m.name)")
                teardown(); return
            }
            screens[m.device] = screen
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        // pick our mode (HiDPI "looks like" size) before arranging, so placement uses the final size
        for m in enabled {
            let hz = lowPowerActive ? min(settings.tuning.lowPowerFps, streamRate(for: m)) : streamRate(for: m)
            screens[m.device]?.setRefreshRate(Double(hz))
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        layoutLocked = true   // macOS's own placement of the new displays must not overwrite the saved one
        placeNewDisplays(enabled)
        restoreLayout(enabled)
        keepMacPrimary()

        for m in enabled {
            guard let screen = screens[m.device] else { continue }
            let port = UInt16(49510 + m.index)
            do {
                let s = try StreamSession(monitor: m, screen: screen, host: host, port: port, settings: settings,
                                          bitrateMbps: prefs(for: m).bitrateMbps)
                s.onError = { [weak self] msg in Task { @MainActor in self?.phase = .error("Capture stopped: \(msg)") } }
                client.start(index: m.index, width: m.width, height: m.height, hz: streamRate(for: m),
                             codec: settings.codec, port: port, vsync: settings.vsync, autoStop: settings.autoStopOnWindowsUse, quietFans: settings.quietFans, gpuLowPower: settings.gpuLowPower, tuning: settings.tuning, covered: prefs(for: m).covered)
                s.setColor(prefs(for: m).color)
                try await s.start(lowPower: lowPowerActive, lowPowerFps: settings.tuning.lowPowerFps, stallMs: settings.tuning.stallMs)
                sessions[m.device] = s
                liveStarts.append((m, port))
            } catch {
                phase = .error(error.localizedDescription)
                client.stopAll()
                teardown()
                return
            }
        }
        guard phase == .starting else { return }
        phase = .live
        // a wake that took this long was a cold boot: turning on from shutdown works, the BIOS is set up
        if let w = wakeStarted, wakeUntil != nil, Date().timeIntervalSince(w) > 40, !settings.wakeFromOffReady {
            settings.wakeFromOffReady = true
            Log.write("wake: PC came up from a full shutdown")
        }
        if settings.restOnStart { client.rest(true, keep: settings.restKeep) }
        wakeUntil = nil
        applyStatsOverlay()
        if settings.restoreWindows {
            var ids: [UInt32: CGDirectDisplayID] = [:]
            for m in enabled { if let sc = screens[m.device] { ids[m.serial] = sc.displayID } }
            let age = TimeInterval(settings.restoreMinutes * 60)
            // let WindowServer finish settling the new displays first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard self?.phase == .live else { return }
                WindowMemory.restore(displays: ids, maxAge: age)
            }
        } else { WindowMemory.forget() }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.phase == .live else { return }
                    self.keepMacPrimary()
                    self.scheduleLayoutSave()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.layoutLocked = false; self?.saveLayout() }
        if CommandLine.arguments.contains("--testpattern") { TestPattern.toggle(on: screens.values.map(\.displayID)) }
        if CommandLine.arguments.contains("--testpattern1"), let m = enabled.first(where: \.primary) ?? enabled.first,
           let id = screens[m.device]?.displayID { TestPattern.toggle(on: [id]) }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for (k, s) in self.sessions { self.stats[k] = s.sampleStats() }
            }
        }
    }

    /// WindowServer never composites a virtual display faster than the fastest real panel (120 Hz
    /// ProMotion here), whatever mode we ask for. Stream at that rate and have Windows run the monitor
    /// at the same rate, so every frame gets exactly one refresh instead of a 1-2-1-1 judder.
    func streamRate(for m: RemoteMonitor) -> Int {
        let macMax = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        return min(m.refreshRate, max(60, macMax))
    }

    /// First time a Windows monitor appears, mirror the Windows layout to the right of the Mac's main display.
    /// After that macOS restores whatever arrangement the user chose (keyed on the display serial).
    private func placeNewDisplays(_ list: [RemoteMonitor]) {
        let fresh = list.filter { !settings.arranged.contains($0.serial) }
        guard !fresh.isEmpty else { return }
        matchWindowsLayout(only: Set(fresh.map(\.device)))
        for m in fresh { settings.arranged.insert(m.serial) }
    }

    func matchWindowsLayout(only: Set<String>? = nil) {
        let main = CGDisplayBounds(CGMainDisplayID())
        let live = monitors.filter { screens[$0.device] != nil }
        guard let minX = live.map(\.x).min() else { return }
        let primaryY = live.first(where: \.primary)?.y ?? live.map(\.y).min() ?? 0
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        for m in live where only?.contains(m.device) ?? true {
            guard let id = screens[m.device]?.displayID else { continue }
            CGConfigureDisplayOrigin(cfg, id, Int32(main.maxX) + Int32(m.x - minX), Int32(main.minY) + Int32(m.y - primaryY))
        }
        CGCompleteDisplayConfiguration(cfg, .permanently)
        keepMacPrimary()
    }

    // MARK: arrangement memory
    // macOS keys its own arrangement memory on the display's exact configuration, so a virtual display
    // that comes back with another size (sharpness, covered area, low power) gets dumped somewhere new.
    // We keep our own copy instead and put every display back ourselves.

    private var layoutLocked = false
    private var layoutSaveTimer: Timer?

    private var macScreenBounds: CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let virtual = Set(screens.values.map(\.displayID))
        let a = ids.prefix(Int(n))
        let mac: CGDirectDisplayID = a.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? a.first(where: { !virtual.contains($0) }) ?? CGMainDisplayID()
        return CGDisplayBounds(mac)
    }

    private func scheduleLayoutSave() {
        guard !layoutLocked else { return }
        layoutSaveTimer?.invalidate()
        layoutSaveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in if self?.phase == .live { self?.saveLayout() } }
        }
    }

    private func saveLayout() {
        guard !layoutLocked else { return }
        let mac = macScreenBounds
        var l = settings.layout
        for m in monitors {
            guard let id = screens[m.device]?.displayID else { continue }
            let b = CGDisplayBounds(id)
            guard b.width > 0 else { continue }
            l[String(m.serial)] = LayoutPos(x: b.minX - mac.minX, y: b.minY - mac.minY, w: b.width, h: b.height)
        }
        if l != settings.layout { settings.layout = l; Log.write("arrangement saved (\(l.count) display(s))") }
    }

    private func restoreLayout(_ list: [RemoteMonitor]) {
        let mac = macScreenBounds
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        var n = 0
        for m in list {
            guard let p = settings.layout[String(m.serial)], let id = screens[m.device]?.displayID else { continue }
            let b = CGDisplayBounds(id)
            var x = p.x, y = p.y
            // same size: exact spot. Otherwise keep whichever side faces the Mac.
            if p.x + p.w <= 0.5 { x = p.x + p.w - b.width }        // left of the Mac: keep its right edge
            if p.y + p.h <= 0.5 { y = p.y + p.h - b.height }       // above the Mac: keep its bottom edge
            CGConfigureDisplayOrigin(cfg, id, Int32((mac.minX + x).rounded()), Int32((mac.minY + y).rounded()))
            n += 1
        }
        if n > 0 { CGCompleteDisplayConfiguration(cfg, .permanently); Log.write("arrangement restored (\(n) display(s))") }
        else { CGCancelDisplayConfiguration(cfg) }
    }

    func toggleTestPattern() { TestPattern.toggle(on: screens.values.map(\.displayID)) }

    /// macOS makes whichever display sits at (0,0) the main one (menu bar, Dock, new windows) and will
    /// sometimes hand that to a freshly created virtual display. Shift the whole arrangement so the Mac's
    /// own screen is back at (0,0); relative positions are preserved.
    func keepMacPrimary() {
        guard settings.keepMacMain else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let active = Array(ids.prefix(Int(n)))
        let virtual = Set(screens.values.map(\.displayID))
        guard let mac = active.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? active.first(where: { !virtual.contains($0) }),
              CGDisplayIsMain(mac) == 0 else { return }
        let o = CGDisplayBounds(mac).origin
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        for id in active {
            let b = CGDisplayBounds(id).origin
            CGConfigureDisplayOrigin(cfg, id, Int32(b.x - o.x), Int32(b.y - o.y))
        }
        CGCompleteDisplayConfiguration(cfg, .permanently)
        Log.write("made the Mac display primary again")
    }

    private func applyStatsOverlay() {
        guard settings.statsOverlay, phase == .live else { StatsOverlay.hide(); return }
        var ids: [String: CGDirectDisplayID] = [:]
        for (d, sc) in screens { ids[d] = sc.displayID }
        StatsOverlay.show(ids)
    }

    /// Hotkey: open the notch editor on the next shared edge; pressing past the last one closes it.
    func alignNextEdge() {
        let links = CursorAligner.shared.links
        guard !links.isEmpty else { return }
        let cur = AlignOverlay.currentLinkID
        AlignOverlay.closeAll()
        let next: CursorAligner.Link?
        if let cur, let i = links.firstIndex(where: { $0.id == cur }) { next = i + 1 < links.count ? links[i + 1] : nil }
        else { next = links.first }
        if let next { AlignOverlay.show(next) { [weak self] in self?.saveAlignment($0) } }
    }

    func presetName(for c: ColorSettings) -> String {
        if c.preset != .custom { return c.preset.rawValue }
        return settings.tuning.colorPresets.first { $0.value == c }?.key ?? "Custom"
    }

    func saveAlignment(_ l: CursorAligner.Link) { settings.edgeNotches[l.id] = l.stored }
    func resetAlignment(_ l: CursorAligner.Link) { settings.edgeNotches[l.id] = nil }

    func virtualDisplayIDs() -> [CGDirectDisplayID: String] {
        var out: [CGDirectDisplayID: String] = [:]
        for m in monitors { if let s = screens[m.device] { out[s.displayID] = m.name } }
        return out
    }

    // MARK: misc

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            phase = .error("Launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
