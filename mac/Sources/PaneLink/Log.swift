import Foundation

/// Tiny append-only log at ~/Library/Logs/PaneLink.log (off the hot path via a serial queue).
enum Log {
    private static let queue = DispatchQueue(label: "panelink.log", qos: .utility)
    private static let handle: FileHandle? = {
        // dev/self-test runs log separately so they never clobber the app's history
        let dev = Bundle.main.bundleIdentifier == nil
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        let url = logs.appendingPathComponent(dev ? "PaneLink-dev.log" : "PaneLink.log")
        // keep history across launches; roll over to PaneLink.old.log past 20 MB
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 20 << 20 {
            let old = logs.appendingPathComponent(dev ? "PaneLink-dev.old.log" : "PaneLink.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

    static func write(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        queue.async { handle?.write(line.data(using: .utf8)!) }
    }
}

/// Lock-protected per-second counters for one stream.
final class Diag {
    private let lock = NSLock()
    private var c: [String: Double] = [:]
    func add(_ k: String, _ v: Double = 1) { lock.lock(); c[k, default: 0] += v; lock.unlock() }
    func max(_ k: String, _ v: Double) { lock.lock(); c[k] = Swift.max(c[k] ?? 0, v); lock.unlock() }
    func drain() -> [String: Double] { lock.lock(); defer { c = [:]; lock.unlock() }; return c }
}
