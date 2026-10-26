import AppKit
import ApplicationServices

/// "Pick up where you left off": when the Windows displays go away, macOS piles their windows onto
/// the Mac screen. Remember where each one was (which display, where on it) and, if extending comes
/// back on soon enough, put them back. Uses Accessibility (same permission as cursor alignment).
@MainActor
enum WindowMemory {
    private struct Saved {
        let window: AXUIElement      // stays valid as long as the window exists
        let pid: pid_t
        let display: UInt32          // virtual display serial (stable per Windows monitor)
        let offset: CGPoint          // top-left relative to that display
        let size: CGSize
    }

    private static var saved: [Saved] = []
    private static var savedAt: Date?

    /// Same list on disk (app + title instead of the live AX handle), so quitting/updating PaneLink while
    /// extending still puts everything back on the next launch.
    private struct Persisted: Codable { let pid: Int32; let bundle: String?; let title: String; let display: UInt32
        let x, y, w, h: Double }
    private struct PersistedSet: Codable { let at: Date; let windows: [Persisted] }
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PaneLink")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("windows.json")
    }

    /// Call while the virtual displays still exist. `displays`: displayID -> serial.
    static func capture(displays: [CGDirectDisplayID: UInt32]) {
        guard AXIsProcessTrusted(), !displays.isEmpty else { return }
        let bounds = displays.keys.map { ($0, CGDisplayBounds($0)) }
        var out: [Saved] = []
        var persisted: [Persisted] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25)   // a hung app must not stall turning off
            for w in attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                guard (attr(w, kAXRoleAttribute) as? String) == kAXWindowRole as String,
                      (attr(w, kAXMinimizedAttribute) as? Bool) != true,
                      (attr(w, "AXFullScreen") as? Bool) != true,
                      let origin = point(w), let size = size(w) else { continue }
                let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + min(size.height / 2, 20))  // title bar decides
                guard let (id, b) = bounds.first(where: { $0.1.contains(center) }), let serial = displays[id] else { continue }
                out.append(Saved(window: w, pid: app.processIdentifier, display: serial,
                                 offset: CGPoint(x: origin.x - b.minX, y: origin.y - b.minY), size: size))
                persisted.append(Persisted(pid: app.processIdentifier, bundle: app.bundleIdentifier, title: attr(w, kAXTitleAttribute) as? String ?? "",
                                           display: serial, x: origin.x - b.minX, y: origin.y - b.minY, w: size.width, h: size.height))
            }
        }
        saved = out
        savedAt = Date()
        if let d = try? JSONEncoder().encode(PersistedSet(at: savedAt!, windows: persisted)) { try? d.write(to: file) }
        Log.write("window memory: remembered \(out.count) window(s) on the Windows displays")
    }

    /// Call once the virtual displays are back and arranged. `displays`: serial -> displayID.
    static func restore(displays: [UInt32: CGDirectDisplayID], maxAge: TimeInterval) {
        defer { saved = []; savedAt = nil; try? FileManager.default.removeItem(at: file) }
        if savedAt == nil { restoreFromDisk(displays: displays, maxAge: maxAge); return }
        guard let at = savedAt, Date().timeIntervalSince(at) <= maxAge, AXIsProcessTrusted() else { return }
        var moved = 0
        for s in saved {
            guard let id = displays[s.display], NSRunningApplication(processIdentifier: s.pid) != nil else { continue }
            let b = CGDisplayBounds(id)
            var p = CGPoint(x: b.minX + s.offset.x, y: b.minY + s.offset.y)
            var sz = s.size
            // position first (so the size fits the right display), size, then position again in case the app clamped
            let pv = AXValueCreate(.cgPoint, &p)!, sv = AXValueCreate(.cgSize, &sz)!
            guard AXUIElementSetAttributeValue(s.window, kAXPositionAttribute as CFString, pv) == .success else { continue }
            AXUIElementSetAttributeValue(s.window, kAXSizeAttribute as CFString, sv)
            AXUIElementSetAttributeValue(s.window, kAXPositionAttribute as CFString, pv)
            moved += 1
        }
        Log.write("window memory: put \(moved) of \(saved.count) window(s) back")
    }

    static func forget() { saved = []; savedAt = nil; try? FileManager.default.removeItem(at: file) }

    /// After a relaunch: match by app (same pid if it's still running, else bundle id) + window title.
    private static func restoreFromDisk(displays: [UInt32: CGDirectDisplayID], maxAge: TimeInterval) {
        guard AXIsProcessTrusted(), let d = try? Data(contentsOf: file),
              let set = try? JSONDecoder().decode(PersistedSet.self, from: d), Date().timeIntervalSince(set.at) <= maxAge else { return }
        var used = Set<String>()
        var moved = 0
        for p in set.windows {
            guard let id = displays[p.display] else { continue }
            let app = NSRunningApplication(processIdentifier: p.pid)
                ?? NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil && $0.bundleIdentifier == p.bundle }
            guard let app else { continue }
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.25)
            let wins = attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
            for (i, w) in wins.enumerated() {
                let key = "\(app.processIdentifier)#\(i)"
                guard !used.contains(key), (attr(w, kAXTitleAttribute) as? String ?? "") == p.title else { continue }
                used.insert(key)
                let b = CGDisplayBounds(id)
                var pt = CGPoint(x: b.minX + p.x, y: b.minY + p.y), sz = CGSize(width: p.w, height: p.h)
                let pv = AXValueCreate(.cgPoint, &pt)!, sv = AXValueCreate(.cgSize, &sz)!
                AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
                AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
                AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
                moved += 1
                break
            }
        }
        Log.write("window memory: put \(moved) of \(set.windows.count) window(s) back after relaunch")
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    private static func point(_ w: AXUIElement) -> CGPoint? {
        guard let v = attr(w, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
    private static func size(_ w: AXUIElement) -> CGSize? {
        guard let v = attr(w, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}
