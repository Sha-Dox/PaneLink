import AppKit
import ApplicationServices
import CoreGraphics

/// Two notches per shared edge, as fractions (0…1) along that edge on each display. Notch 1 on one
/// display is the same physical spot as notch 1 on the other, same for notch 2; everything in between
/// (and beyond) is interpolated linearly. Stored in the order of the displays' stable keys.
struct EdgeNotches: Codable, Equatable {
    var f1: Double, f2: Double   // display with the smaller key
    var s1: Double, s2: Double   // the other one
}

/// LittleBigMouse for macOS: macOS moves the cursor between displays in points, so a 27" 1440p panel
/// next to a 14" Retina screen lines up wrong (and you can't cross where the shorter one ends). We
/// watch mouse moves/drags with an event tap and, whenever the cursor crosses (or pushes against) a
/// shared edge, put it where the notches say it physically belongs. Dragged windows follow the cursor.
final class CursorAligner: ObservableObject {
    static let shared = CursorAligner()

    struct Disp: Equatable {
        let id: CGDirectDisplayID
        let key: String
        let name: String
        let frame: CGRect          // global CG coordinates (y down)
        let mmPerPt: Double
    }

    /// `vertical`: a is left of b. Otherwise a is above b. Notches oriented a/b.
    struct Link: Identifiable, Equatable {
        let a: Disp, b: Disp
        let vertical: Bool
        var a1: Double, a2: Double, b1: Double, b2: Double
        var id: String { Self.storageKey(a, b, vertical) }
        var title: String { "\(a.name)  \(vertical ? "⇆" : "⇅")  \(b.name)" }

        static func storageKey(_ x: Disp, _ y: Disp, _ vertical: Bool) -> String {
            let (p, q) = x.key < y.key ? (x.key, y.key) : (y.key, x.key)
            return "\(p)|\(q)|\(vertical ? "v" : "h")"
        }
        var stored: EdgeNotches { a.key < b.key ? EdgeNotches(f1: a1, f2: a2, s1: b1, s2: b2) : EdgeNotches(f1: b1, f2: b2, s1: a1, s2: a2) }

        func len(_ d: Disp) -> CGFloat { vertical ? d.frame.height : d.frame.width }
        func start(_ d: Disp) -> CGFloat { vertical ? d.frame.minY : d.frame.minX }

        /// Fraction along the edge on `from` -> fraction on the other display.
        func map(_ u: Double, from: Disp) -> Double {
            if from.id == a.id { return abs(a2 - a1) < 1e-6 ? u : b1 + (u - a1) * (b2 - b1) / (a2 - a1) }
            return abs(b2 - b1) < 1e-6 ? u : a1 + (u - b1) * (a2 - a1) / (b2 - b1)
        }
        func other(_ d: Disp) -> Disp { d.id == a.id ? b : a }
    }

    @Published private(set) var links: [Link] = []
    @Published private(set) var trusted = AXIsProcessTrusted()

    /// Supplies the saved notches and the on/off switch (AppState settings).
    var settingsProvider: () -> (enabled: Bool, notches: [String: EdgeNotches]) = { (false, [:]) }

    private let lock = NSLock()
    private var snapLinks: [Link] = []
    private var snapDisps: [Disp] = []
    private var snapEnabled = false
    var last = CGPoint(x: -1e9, y: -1e9)
    private var tap: CFMachPort?
    private var observer: NSObjectProtocol?
    private var trustTimer: Timer?

    func activate() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // give WindowServer a moment to settle the new arrangement
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.rebuild() }
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = AXIsProcessTrusted()
            if t != self.trusted { self.trusted = t; self.rebuild() }
        }
        rebuild()
    }

    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
        if !trusted {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    // MARK: geometry

    static func displayKey(_ id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    func currentDisplays() -> [Disp] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (id, s.localizedName)
        })
        return ids.prefix(Int(n)).compactMap { id in
            guard CGDisplayIsInMirrorSet(id) == 0 || CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            let f = CGDisplayBounds(id)
            let mm = CGDisplayScreenSize(id)
            let mmPerPt = mm.width > 0 && f.width > 0 ? Double(mm.width / f.width) : 0.25
            return Disp(id: id, key: Self.displayKey(id), name: names[id] ?? "Display \(id)", frame: f, mmPerPt: mmPerPt)
        }
    }

    /// Default notches: line the edges up at the top/left of the overlap and scale by physical size.
    static func physicalDefault(a: Disp, b: Disp, vertical: Bool) -> (Double, Double, Double, Double) {
        let aStart = vertical ? a.frame.minY : a.frame.minX, aLen = vertical ? a.frame.height : a.frame.width
        let bStart = vertical ? b.frame.minY : b.frame.minX, bLen = vertical ? b.frame.height : b.frame.width
        let o = max(aStart, bStart)
        let a1 = Double((o - aStart) / aLen), b1 = Double((o - bStart) / bLen)
        let mmA = Double(aStart + aLen - o) * a.mmPerPt, mmB = Double(bStart + bLen - o) * b.mmPerPt
        let m = min(mmA, mmB) * 0.9
        return (a1, a1 + m / a.mmPerPt / Double(aLen), b1, b1 + m / b.mmPerPt / Double(bLen))
    }

    func rebuild() {
        let disps = currentDisplays()
        let s = settingsProvider()
        var out: [Link] = []
        for (i, p) in disps.enumerated() {
            for q in disps[(i + 1)...] {
                for (x, y) in [(p, q), (q, p)] {
                    // x left of y, sharing part of a vertical edge
                    if abs(x.frame.maxX - y.frame.minX) < 0.5, min(x.frame.maxY, y.frame.maxY) - max(x.frame.minY, y.frame.minY) > 0 {
                        out.append(makeLink(x, y, vertical: true, saved: s.notches))
                    }
                    // x above y
                    if abs(x.frame.maxY - y.frame.minY) < 0.5, min(x.frame.maxX, y.frame.maxX) - max(x.frame.minX, y.frame.minX) > 0 {
                        out.append(makeLink(x, y, vertical: false, saved: s.notches))
                    }
                }
            }
        }
        links = out
        lock.lock()
        snapLinks = out; snapDisps = disps; snapEnabled = s.enabled
        lock.unlock()
        // the tap also gives fullscreen apps their top edge back (see holdAtTop), so it runs with
        // more than one display even when alignment is off
        if trusted && (s.enabled && out.count > 0 || disps.count > 1) { startTap() }
    }

    private func makeLink(_ a: Disp, _ b: Disp, vertical: Bool, saved: [String: EdgeNotches]) -> Link {
        let key = Link.storageKey(a, b, vertical)
        if let n = saved[key] {
            let (an, bn) = a.key < b.key ? ((n.f1, n.f2), (n.s1, n.s2)) : ((n.s1, n.s2), (n.f1, n.f2))
            return Link(a: a, b: b, vertical: vertical, a1: an.0, a2: an.1, b1: bn.0, b2: bn.1)
        }
        let d = Self.physicalDefault(a: a, b: b, vertical: vertical)
        return Link(a: a, b: b, vertical: vertical, a1: d.0, a2: d.1, b1: d.2, b2: d.3)
    }

    // MARK: event tap

    private func startTap() {
        guard tap == nil else { return }
        // A warp normally suppresses local mouse events for 0.25 s: the cursor visibly stalls at every
        // crossing and loses its glide. We warp on purpose, mid-motion, so turn that off.
        if let src = CGEventSource(stateID: .combinedSessionState) { src.localEventsSuppressionInterval = 0 }
        if let src = CGEventSource(stateID: .hidSystemState) { src.localEventsSuppressionInterval = 0 }
        let mask: CGEventMask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, refcon in
            let me = Unmanaged<CursorAligner>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            me.handle(event, dragging: type != .mouseMoved)
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else {
            Log.write("cursor align: couldn't create event tap (Accessibility permission?)")
            return
        }
        tap = t
        // its own thread: the main thread can be busy with SwiftUI, the cursor must never wait on it
        let th = Thread {
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "cursor-align"
        th.qualityOfService = .userInteractive
        th.start()
        Log.write("cursor align: event tap running")
    }

    private enum Side { case left, right, top, bottom }

    func handle(_ e: CGEvent, dragging: Bool = false) {
        lock.lock()
        let links = snapLinks, disps = snapDisps, enabled = snapEnabled
        lock.unlock()
        let p = e.location
        func inside(_ d: Disp, _ q: CGPoint) -> Bool {
            q.x >= d.frame.minX && q.x < d.frame.maxX && q.y >= d.frame.minY && q.y < d.frame.maxY
        }
        let from = disps.first { inside($0, last) }
        let to = disps.first { inside($0, p) }
        if !dragging, let f = from, let held = holdAtTop(f, to: to, p: p, dy: e.getDoubleValueField(.mouseEventDeltaY)) {
            CGWarpMouseCursorPosition(held)
            CGAssociateMouseAndMouseCursorPosition(1)
            e.location = held
            last = held
            return
        }
        guard enabled, !links.isEmpty else { last = p; return }
        var target: CGPoint?
        if let f = from, let t = to, f.id != t.id {
            target = crossed(from: f, to: t, p: p, links: links)
        } else if let f = from {
            target = pushed(from: f, p: p, dx: e.getDoubleValueField(.mouseEventDeltaX),
                            dy: e.getDoubleValueField(.mouseEventDeltaY), links: links, disps: disps)
        }
        if let t = target {
            CGWarpMouseCursorPosition(t)
            CGAssociateMouseAndMouseCursorPosition(1)
            e.location = t
            last = t
        } else {
            last = p
        }
    }

    // MARK: fullscreen top edge
    // A fullscreen app shows its menu bar / tab strip (Chrome, Safari…) only while the cursor rests on
    // the top edge. With a display above, macOS moves the cursor straight onto it instead, so they never
    // appear. On a display showing a fullscreen window the top edge stops the cursor; keep pushing
    // up (holdPushPt) to cross anyway.

    static let holdPushPt = 90.0
    private var pushed = 0.0, pushedAt = 0.0
    private var fsCache: [CGDirectDisplayID: (Bool, Double)] = [:]

    private func holdAtTop(_ f: Disp, to t: Disp?, p: CGPoint, dy: Double) -> CGPoint? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - pushedAt > 0.8 { pushed = 0 }          // a pause starts a fresh push
        guard p.y < f.frame.minY, dy < 0, isFullscreen(f) else {
            if p.y > f.frame.minY + 3 { pushed = 0 }
            return nil
        }
        _ = t
        pushed += -dy; pushedAt = now
        if pushed >= Self.holdPushPt { pushed = 0; return nil }   // meant it: let macOS cross
        return CGPoint(x: min(max(p.x, f.frame.minX), f.frame.maxX - 1), y: f.frame.minY)
    }

    /// Some app window covers the whole display (fullscreen Space). Cached briefly: this runs on mouse moves.
    private func isFullscreen(_ d: Disp) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let c = fsCache[d.id], now - c.1 < 0.5 { return c.0 }
        var fs = false
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
                guard let bd = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd) else { continue }
                if abs(r.minX - d.frame.minX) < 1 && abs(r.minY - d.frame.minY) < 1 && abs(r.width - d.frame.width) < 1 && abs(r.height - d.frame.height) < 1 { fs = true; break }
            }
        }
        fsCache[d.id] = (fs, now)
        return fs
    }

    private func side(of d: Disp, in l: Link) -> Side {
        l.vertical ? (l.a.id == d.id ? .right : .left) : (l.a.id == d.id ? .bottom : .top)
    }

    /// macOS moved the cursor onto a neighbour: correct where along the edge it landed.
    private func crossed(from f: Disp, to t: Disp, p: CGPoint, links: [Link]) -> CGPoint? {
        guard let l = links.first(where: { ($0.a.id == f.id && $0.b.id == t.id) || ($0.a.id == t.id && $0.b.id == f.id) }) else { return nil }
        let s = side(of: f, in: l)
        let u = fraction(on: f, l, l.vertical ? p.y : p.x)
        // a mapped spot may belong to another display on the same side (two monitors stacked)
        for c in links where c.a.id == f.id || c.b.id == f.id {
            guard c.vertical == l.vertical, side(of: f, in: c) == s else { continue }
            let v = c.map(u, from: f)
            if v >= 0 && v < 1 { return point(on: c.other(f), c, v, entering: s, p: p) }
        }
        return point(on: t, l, min(max(l.map(u, from: f), 0), 0.9999), entering: s, p: p)
    }

    /// The cursor is pressed against an edge where macOS has nothing next to it, but our mapping does.
    private func pushed(from f: Disp, p: CGPoint, dx: Double, dy: Double, links: [Link], disps: [Disp]) -> CGPoint? {
        var s: Side?
        var probe = p
        if dx > 0 && p.x >= f.frame.maxX - 1 { s = .right; probe.x = f.frame.maxX + 0.5 }
        else if dx < 0 && p.x <= f.frame.minX + 0.5 { s = .left; probe.x = f.frame.minX - 0.5 }
        else if dy > 0 && p.y >= f.frame.maxY - 1 { s = .bottom; probe.y = f.frame.maxY + 0.5 }
        else if dy < 0 && p.y <= f.frame.minY + 0.5 { s = .top; probe.y = f.frame.minY - 0.5 }
        guard let side = s else { return nil }
        if disps.contains(where: { $0.frame.contains(probe) }) { return nil }   // macOS crosses here itself
        for c in links where (c.a.id == f.id || c.b.id == f.id) && self.side(of: f, in: c) == side {
            let u = fraction(on: f, c, c.vertical ? p.y : p.x)
            let v = c.map(u, from: f)
            if v >= 0 && v < 1 { return point(on: c.other(f), c, v, entering: side, p: p) }
        }
        return nil
    }

    private func fraction(on d: Disp, _ l: Link, _ coord: CGFloat) -> Double {
        Double(min(max((coord - l.start(d)) / l.len(d), 0), 0.9999))
    }

    /// A spot just inside display `d`, `v` of the way along the shared edge.
    private func point(on d: Disp, _ l: Link, _ v: Double, entering s: Side, p: CGPoint) -> CGPoint {
        let along = l.start(d) + CGFloat(v) * l.len(d)
        let fr = d.frame
        switch s {
        case .right:  return CGPoint(x: min(max(p.x, fr.minX), fr.minX + 4), y: along)
        case .left:   return CGPoint(x: max(min(p.x, fr.maxX - 1), fr.maxX - 5), y: along)
        case .bottom: return CGPoint(x: along, y: min(max(p.y, fr.minY), fr.minY + 4))
        case .top:    return CGPoint(x: along, y: max(min(p.y, fr.maxY - 1), fr.maxY - 5))
        }
    }
}
