import Foundation

/// Keeps the Mac's Wi-Fi radio on the access point's channel while streaming.
///
/// awdl0 (AirDrop/AirPlay/Sidecar mesh) makes the Wi-Fi card hop to the social channels roughly
/// once a second. Every hop parks outgoing packets in the driver for ~100 ms, which shows up as a
/// periodic stutter on the remote displays. macOS re-enables it whenever something asks for
/// AirDrop/Handoff, so a gentle watchdog keeps it down. llw0 is left alone: forcing it down too
/// made macOS reset Wi-Fi.
enum WiFiTuner {
    static let interfaces = ["awdl0"]
    private static let sudoIfaces = ["awdl0", "llw0"]   // sudoers rule also restores llw0 from v1
    private static let sudoers = "/etc/sudoers.d/panelink"
    private static var timer: DispatchSourceTimer?
    private static let queue = DispatchQueue(label: "panelink.wifi", qos: .userInitiated)

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: sudoers) }

    /// One admin prompt: allow exactly `ifconfig awdl0|llw0 up|down` without a password.
    @discardableResult
    static func install() -> Bool {
        let user = NSUserName()
        let rules = sudoIfaces.flatMap { i in ["up", "down"].map { "/sbin/ifconfig \(i) \($0)" } }.joined(separator: ", ")
        let line = "\(user) ALL=(root) NOPASSWD: \(rules)"
        let sh = "echo '\(line)' > /tmp/panelink.sudoers && /usr/sbin/visudo -cf /tmp/panelink.sudoers && "
            + "/usr/sbin/chown root:wheel /tmp/panelink.sudoers && /bin/chmod 0440 /tmp/panelink.sudoers && "
            + "/bin/mv /tmp/panelink.sudoers \(sudoers)"
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(sh)\" with administrator privileges")?.executeAndReturnError(&err)
        if let err { Log.write("wifi: sudoers install failed \(err)") }
        return isInstalled
    }

    static func begin() {
        queue.async {
            guard isInstalled || install() else { return }
            setAll(up: false)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 3, repeating: 3)
            t.setEventHandler {
                for i in interfaces where isUp(i) {
                    Log.write("wifi: \(i) came back up, disabling again")
                    WiFiMonitor.shared.note("\(i) came back up")
                    run(i, up: false)
                }
            }
            t.resume()
            timer = t
        }
    }

    /// Synchronous so it completes even when called from applicationWillTerminate / a signal.
    static func end() {
        queue.sync {
            timer?.cancel()
            timer = nil
            if isInstalled { setAll(up: true) }
        }
    }

    private static func setAll(up: Bool) {
        for i in interfaces { run(i, up: up) }
        Log.write("wifi: \(interfaces.joined(separator: ",")) \(up ? "up" : "down")")
    }

    private static func run(_ iface: String, up: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/sbin/ifconfig", iface, up ? "up" : "down"]
        try? p.run()
        p.waitUntilExit()
    }

    private static func isUp(_ iface: String) -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return false }
        defer { freeifaddrs(addrs) }
        var p = addrs
        while let a = p {
            if String(cString: a.pointee.ifa_name) == iface { return (a.pointee.ifa_flags & UInt32(IFF_UP)) != 0 }
            p = a.pointee.ifa_next
        }
        return false
    }
}
