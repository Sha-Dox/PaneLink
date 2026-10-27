import AppKit
import ApplicationServices
import SwiftUI

/// `PaneLink --aligntest`: local-only check of the cursor remapper with a temporary virtual display.
enum AlignSelfTest {
    static func run() {
        let out = { (s: String) in FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        out("accessibility trusted: \(AXIsProcessTrusted())")
        guard let vs = VirtualScreen(name: "AlignTest", width: 2560, height: 1440, refreshRate: 60, serial: 0xA11A7E57) else { out("no vdisplay"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
            CGGetActiveDisplayList(16, &ids, &n)
            let mac = ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }!
            let mb = CGDisplayBounds(mac)
            var cfg: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&cfg)
            CGConfigureDisplayOrigin(cfg, mac, 0, 0)
            CGConfigureDisplayOrigin(cfg, vs.displayID, Int32(mb.width), 0)
            CGCompleteDisplayConfiguration(cfg, .forSession)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let a = CursorAligner.shared
                a.settingsProvider = { (true, [:]) }
                a.rebuild()
                let mbb = CGDisplayBounds(mac), vb = CGDisplayBounds(vs.displayID)
                out("mac \(mbb) mm \(CGDisplayScreenSize(mac))  virtual \(vb) mm \(CGDisplayScreenSize(vs.displayID))")
                for l in a.links { out("link \(l.title) a=\(l.a1),\(l.a2) b=\(l.b1),\(l.b2)") }
                func step(_ from: CGPoint, _ to: CGPoint, dx: Double, dy: Double) -> CGPoint {
                    a.last = from
                    let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: to, mouseButton: .left)!
                    e.setDoubleValueField(.mouseEventDeltaX, value: dx); e.setDoubleValueField(.mouseEventDeltaY, value: dy)
                    a.handle(e)
                    return e.location
                }
                let x = mbb.maxX
                for y in [100.0, 500, 900] {
                    out("cross mac->win at y=\(y): \(step(CGPoint(x: x - 1, y: y), CGPoint(x: x + 2, y: y), dx: 3, dy: 0))")
                }
                for y in [100.0, 430, 800, 1000, 1300] {
                    // macOS crosses itself where the Mac is beside it; below that we must push
                    let r = y < 982 ? step(CGPoint(x: x + 1, y: y), CGPoint(x: x - 2, y: y), dx: -3, dy: 0)
                                    : step(CGPoint(x: x, y: y), CGPoint(x: x, y: y), dx: -3, dy: 0)
                    out("win->mac at y=\(y): \(r)")
                }
                // saved notches: identity 0..1 both sides -> full edge maps to full edge
                a.settingsProvider = { (true, [CursorAligner.Link.storageKey(a.links[0].a, a.links[0].b, true): EdgeNotches(f1: 0, f2: 1, s1: 0, s2: 1)]) }
                a.rebuild()
                out("full-edge: win y=1400 -> \(step(CGPoint(x: x, y: 1400), CGPoint(x: x, y: 1400), dx: -3, dy: 0))  mac y=491 -> \(step(CGPoint(x: x - 1, y: 491), CGPoint(x: x + 2, y: 491), dx: 3, dy: 0))")
                if CommandLine.arguments.contains("--overlay") {
                    AlignOverlay.show(a.links[0]) { l in out("notch change a=\(l.a1),\(l.a2) b=\(l.b1),\(l.b2)") }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let dir = ProcessInfo.processInfo.environment["SHOTDIR"] ?? "/tmp"
                        for (i, id) in [mac, vs.displayID].enumerated() {
                            out("display \(id) bounds \(CGDisplayBounds(id)) main=\(CGDisplayIsMain(id)) mirror=\(CGDisplayMirrorsDisplay(id))")
                            guard let img = CGDisplayCreateImage(id) else { out("no image \(id)"); continue }
                            let rep = NSBitmapImageRep(cgImage: img)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/ov\(i + 1).png"))
                        }
                        for w in NSApp.windows where w.isVisible { out("window \(w.frame) on \(w.screen?.localizedName ?? "-")") }
                        exit(0)
                    }
                } else { exit(0) }
            }
        }
    }

    static var keep: [AnyObject] = []

    /// helper process: one plain window, top-left at the CG point given in argv
    static func dummyWindow() {
        let a = CommandLine.arguments
        let x = Double(a[a.count - 2])!, y = Double(a[a.count - 1])!
        let h = CGDisplayBounds(CGMainDisplayID()).height
        let w = NSWindow(contentRect: NSRect(x: x, y: h - y - 500, width: 800, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.title = "WindowMemoryTest"
        w.setFrameTopLeftPoint(NSPoint(x: x, y: h - y))
        w.orderFrontRegardless()
        keep.append(w)
        NSApp.setActivationPolicy(.regular)
    }

    @MainActor static func windowTest() {
        let out = { (s: String) in FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        let serial: UInt32 = 0xA11A7E58
        func make() -> VirtualScreen { VirtualScreen(name: "WinMemTest", width: 2560, height: 1440, refreshRate: 60, serial: serial)! }
        func place(_ vs: VirtualScreen) {
            var cfg: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&cfg)
            CGConfigureDisplayOrigin(cfg, CGMainDisplayID(), 0, 0)
            CGConfigureDisplayOrigin(cfg, vs.displayID, Int32(CGDisplayBounds(CGMainDisplayID()).width), 0)
            CGCompleteDisplayConfiguration(cfg, .forSession)
        }
        var vs: VirtualScreen? = make()
        let helper = Process()
        func frame() -> String {
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            let w = list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == helper.processIdentifier && ($0[kCGWindowName as String] as? String) == "WindowMemoryTest" }
            return "\(w?[kCGWindowBounds as String] ?? "none")"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            place(vs!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let vb = CGDisplayBounds(vs!.displayID)
                helper.launchPath = CommandLine.arguments[0]
                helper.arguments = ["--dummywindow", "\(vb.minX + 300)", "\(vb.minY + 200)"]
                helper.launch()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    out("virtual display at \(vb); window before: \(frame())")
                    WindowMemory.capture(displays: [vs!.displayID: serial])
                    vs = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        out("display removed; window now: \(frame())")
                        vs = make()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            place(vs!)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                WindowMemory.restore(displays: [serial: vs!.displayID], maxAge: 600)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    out("display back at \(CGDisplayBounds(vs!.displayID)); window now: \(frame())")
                                    helper.terminate(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor static func overlayTest() {
        let vs = VirtualScreen(name: "OverlayTest", width: 2560, height: 1440, refreshRate: 60, serial: 0xA11A7E59)!
        keep.append(vs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var st = StreamStats(); st.fps = 119.8; st.encodeMs = 5.2; st.networkMs = 1.3; st.displayMs = 0.8
            st.lostFrames = 0; st.mbps = 61; st.refreshRate = 120
            AppState.shared.stats["TEST"] = st
            StatsOverlay.show(["TEST": vs.displayID])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let dir = ProcessInfo.processInfo.environment["SHOTDIR"] ?? "/tmp"
                if let img = CGDisplayCreateImage(vs.displayID) {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/overlay.png"))
                }
                exit(0)
            }
        }
    }

    /// Loopback: fake viewer sends heartbeats, goes silent 400 ms, comes back. Expect sends to pause, then resume + keyframe.
    static func stallTest() {
        let out = { (s: String) in FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        let port: UInt16 = 49599
        let vfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(vfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var tv = timeval(tv_sec: 0, tv_usec: 2000); setsockopt(vfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let sender = VideoSender(host: "127.0.0.1", port: port, groupSize: 8)!
        var resumes = 0
        sender.onResume = { resumes += 1 }
        let frame = [UInt8](repeating: 0xAB, count: 60_000)
        var peer = sockaddr_in(); var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size); var havePeer = false
        var recvFrames = Set<UInt32>(), sent = 0
        let t0 = nowUs()
        var lastBeat: UInt64 = 0, lastFrame: UInt64 = 0
        var timeline: [String] = []
        var lastState = ""
        while nowUs() - t0 < 1_400_000 {
            let t = nowUs() - t0
            if nowUs() - lastFrame >= 8333 {
                lastFrame = nowUs()
                frame.withUnsafeBytes { sender.send(frame: $0, keyframe: false, timestampUs: 0) }
                sent += 1
            }
            var buf = [UInt8](repeating: 0, count: 2048)
            let n = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(vfd, &buf, 2048, 0, $0, &peerLen) } }
            if n >= 20 { havePeer = true; recvFrames.insert(buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }) }
            let silent = t > 500_000 && t < 900_000
            if havePeer && !silent && nowUs() - lastBeat > 20_000 {
                var hb: [UInt8] = [0x12, 0, 0, 0, 0, 0, 0, 0]
                _ = withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(vfd, &hb, 8, 0, $0, peerLen) } }
                lastBeat = nowUs()
            }
            let st = sender.stalled ? "stalled" : "flowing"
            if st != lastState { timeline.append("\(t / 1000)ms \(st)"); lastState = st }
        }
        out("frames offered \(sent), frame numbers used \(sender.framesSent), distinct received \(recvFrames.count), resumes \(resumes)")
        out("timeline: " + timeline.joined(separator: ", "))
        exit(0)
    }

    @MainActor static func uiShot() {
        let dir = ProcessInfo.processInfo.environment["SHOTDIR"] ?? "/tmp"
        NSApp.setActivationPolicy(.regular)
        if let icon = ProcessInfo.processInfo.environment["ICON"], let img = NSImage(contentsOfFile: icon) { NSApp.applicationIconImage = img }
        if ProcessInfo.processInfo.environment["CLEAN"] != nil { AppState.shared.settings.wakeFromOffReady = true }   // README shots: no banners
        let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 760, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: MainWindow(state: AppState.shared))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let tabs = ["displays", "performance", "controls", "windows"]
        func shootMenu() {
            // the menu bar panel, in a plain window
            let m = NSWindow(contentRect: NSRect(x: 900, y: 300, width: 340, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: MenuBarView(state: AppState.shared).background(.regularMaterial))
            m.contentView = host
            m.setContentSize(host.fittingSize)
            m.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(m.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/menu.png"))
                }
                exit(0)
            }
        }
        func shoot(_ i: Int) {
            guard i < tabs.count else { shootMenu(); return }
            UserDefaults.standard.set(tabs[i], forKey: "mainTab")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/tab-\(tabs[i]).png"))
                }
                shoot(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { shoot(0) }
    }

    /// `--hidpitest`: HiDPI virtual display gets a 2560x1440-point mode backed by 5120x2880, and SCK can capture it at native size.
    static func hiDPITest() {
        let out = { (s: String) in FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard let vs = VirtualScreen(name: "HiDPITest", width: 2560, height: 1440, refreshRate: 120, serial: 0xA11A7E5A, hiDPI: true) else { out("create failed"); exit(1) }
        keep.append(vs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            for m in (CGDisplayCopyAllDisplayModes(vs.displayID, opts) as? [CGDisplayMode]) ?? [] {
                out("  mode \(m.width)x\(m.height) px \(m.pixelWidth)x\(m.pixelHeight) @\(m.refreshRate) usable=\(m.isUsableForDesktopGUI())")
            }
            let ok = vs.setRefreshRate(120)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let m = CGDisplayCopyDisplayMode(vs.displayID)
                out("setMode \(ok): bounds \(CGDisplayBounds(vs.displayID)) mode \(m?.width ?? 0)x\(m?.height ?? 0) px \(m?.pixelWidth ?? 0)x\(m?.pixelHeight ?? 0) @\(m?.refreshRate ?? 0)")
                let ok60 = vs.setRefreshRate(60)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let m2 = CGDisplayCopyDisplayMode(vs.displayID)
                    out("low power \(ok60): \(m2?.width ?? 0)x\(m2?.height ?? 0) px \(m2?.pixelWidth ?? 0) @\(m2?.refreshRate ?? 0)")
                    let dir = ProcessInfo.processInfo.environment["SHOTDIR"] ?? "/tmp"
                    if let img = CGDisplayCreateImage(vs.displayID) {
                        out("display image \(img.width)x\(img.height)")
                        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/hidpi.png"))
                    }
                    exit(0)
                }
            }
        }
    }

    /// `--pipetest [hidpi]`: both monitor shapes, animated test pattern, real capture + encode (UDP to localhost), 6 s.
    @MainActor static func pipeTest() {
        let hi = CommandLine.arguments.contains("hidpi")
        let out = { (s: String) in FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        let mons = [RemoteMonitor(index: 0, x: 0, y: 0, width: 2560, height: 1440, refreshRate: 144, primary: true, device: "T0", name: "T1440"),
                    RemoteMonitor(index: 1, x: 2560, y: 0, width: 1080, height: 1920, refreshRate: 144, primary: false, device: "T1", name: "TPortrait")]
        var sessions: [StreamSession] = []
        for (i, m) in mons.enumerated() {
            let vs = VirtualScreen(name: m.name, width: m.width, height: m.height, refreshRate: 120, serial: 0xA11A7E60 + UInt32(i), hiDPI: hi)!
            keep.append(vs)
            let s = try! StreamSession(monitor: m, screen: vs, host: "127.0.0.1", port: UInt16(49590 + i), settings: Settings(),
                                       bitrateMbps: Settings.defaultBitrate(for: m))
            sessions.append(s)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for s in sessions { s.screen.setRefreshRate(120) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            for s in sessions { try! await s.start(lowPower: false) }
            TestPattern.toggle(on: sessions.map { $0.screen.displayID })
            for _ in sessions { }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            _ = sessions.map { $0.sampleStats() }
            for sec in 1...5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let line = sessions.map { s -> String in
                    let st = s.sampleStats()
                    return String(format: "%@ %.0ffps enc %.1fms %.0fMbps", s.monitor.name, st.fps, st.encodeMs, st.mbps)
                }.joined(separator: " | ")
                out("\(hi ? "HiDPI" : "1x   ") t=\(sec)s  " + line)
            }
            exit(0)
        }
    }
}
