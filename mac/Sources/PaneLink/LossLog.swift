import AppKit
import CoreWLAN
import Foundation

/// Viewer's account of one loss (0x13, see PROTOCOL.md): the frame it gave up on and how recovery went.
struct LossReport {
    var trigger: Int            // 1 newer frame arrived first, 2 gap found at completion, 3 decoder stall, 4 renderer queue full
    var startFrame: UInt32
    var frames: Int             // frames skipped until the keyframe showed
    var pkts, got, parity, broken: Int
    var gapUs, recoverUs: Int
    var idrReqs, keysSeen: Int
    var frameBytes, keyBytes: Int
}

/// Samples the Mac's Wi-Fi link while streaming, so a loss can be put next to what the radio was doing.
final class WiFiMonitor {
    static let shared = WiFiMonitor()
    struct Sample { let t: UInt64; let rssi: Int; let noise: Int; let txRate: Double; let channel: Int }

    private let queue = DispatchQueue(label: "panelink.wifimon", qos: .utility)
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var events: [(UInt64, String)] = []
    private var timer: DispatchSourceTimer?
    private var users = 0

    func retain() {
        queue.async {
            self.users += 1
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.sample() }
            t.resume()
            self.timer = t
        }
    }

    func release() {
        queue.async {
            self.users = max(0, self.users - 1)
            if self.users == 0 { self.timer?.cancel(); self.timer = nil }
        }
    }

    /// Something happened to the link (AWDL back up, …).
    func note(_ what: String) {
        lock.lock(); events.append((nowUs(), what)); if events.count > 64 { events.removeFirst() }; lock.unlock()
    }

    private func sample() {
        guard let i = CWWiFiClient.shared().interface() else { return }
        let s = Sample(t: nowUs(), rssi: i.rssiValue(), noise: i.noiseMeasurement(), txRate: i.transmitRate(), channel: i.wlanChannel()?.channelNumber ?? 0)
        lock.lock()
        if let last = samples.last, last.channel != 0, s.channel != 0, last.channel != s.channel {
            events.append((s.t, "channel \(last.channel) → \(s.channel)"))
        }
        samples.append(s)
        if samples.count > 300 { samples.removeFirst(samples.count - 300) }   // 60 s
        lock.unlock()
    }

    func window(from: UInt64, to: UInt64) -> (samples: [Sample], events: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (samples.filter { $0.t >= from && $0.t <= to }, events.filter { $0.0 >= from && $0.0 <= to }.map(\.1))
    }
}

/// Every recovered loss, with a cause, kept so it's clear what to improve next.
/// History: ~/Library/Logs/PaneLink-loss.jsonl (one JSON object per loss).
@MainActor
final class LossLog: ObservableObject {
    static let shared = LossLog()

    enum Cause: String, Codable, CaseIterable, Identifiable {
        case dropout = "Wi-Fi dropout"
        case burst = "Packet loss burst"
        case macQueue = "Mac Wi-Fi queue full"
        case windowsBusy = "Windows decoder/renderer stalled"
        case unknown = "Unclear"
        var id: String { rawValue }
        var advice: String {
            switch self {
            case .dropout: "The link went silent (nothing arrived for a while). Usually the Mac's Wi-Fi: interference, roaming, a channel change or AWDL. 5 GHz close to the router, or a USB-C Ethernet adapter, fixes it."
            case .burst: "Packets arrived, but more went missing than the packet-loss protection can repair. Try Strong protection (Performance → Stream) or a lower bitrate."
            case .macQueue: "The Mac's Wi-Fi couldn't send fast enough and the frame was cut on the Mac. Lower the bitrate for that monitor."
            case .windowsBusy: "Windows couldn't decode/show frames in time (a game or heavy app on the PC). Rest PC helps."
            case .unknown: "Not enough information. These are rare; the details are in the log."
            }
        }
    }

    struct Event: Codable, Identifiable {
        var id = UUID()
        var at: Date
        var monitor: String
        var cause: Cause
        var frames: Int
        var recoverMs: Double
        var detail: String
        var rssi: Int?
        var gapMs: Double
        var packets: String        // "got/expected (+parity)"
        var frameKB: Double
        var keyKB: Double
        var keyTries: Int
    }

    @Published private(set) var events: [Event] = []
    private let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PaneLink-loss.jsonl")
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    init() {
        // last few hundred from earlier runs
        if let d = try? String(contentsOf: file, encoding: .utf8) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            events = d.split(separator: "\n").suffix(300).compactMap { try? dec.decode(Event.self, from: Data($0.utf8)) }
        }
    }

    func add(_ e: Event) {
        events.append(e)
        if events.count > 300 { events.removeFirst(events.count - 300) }
        Log.write("loss [\(e.monitor)] \(e.cause.rawValue): \(e.frames) frame(s), \(e.detail)")
        guard let d = try? encoder.encode(e) else { return }
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(d + Data("\n".utf8)); try? h.close() }
    }

    func clear() {
        events.removeAll()
        try? FileManager.default.removeItem(at: file)
    }

    func openFile() { NSWorkspace.shared.open(file) }

    /// Totals per cause for events newer than `since`.
    func summary(since: Date) -> [(cause: Cause, events: Int, frames: Int)] {
        let recent = events.filter { $0.at >= since }
        return Cause.allCases.compactMap { c in
            let e = recent.filter { $0.cause == c }
            return e.isEmpty ? nil : (c, e.count, e.reduce(0) { $0 + $1.frames })
        }.sorted { $0.frames > $1.frames }
    }

    /// Puts the viewer's report next to what the Mac sent and what its Wi-Fi was doing.
    nonisolated static func classify(_ r: LossReport, monitor: String, sender: VideoSender, fecGroup: Int) -> Event {
        let now = nowUs()
        let sent = sender.sentFrame(r.startFrame)
        let ref = sent?.sentUs ?? (now - UInt64(r.recoverUs))
        let from = ref &- 1_000_000, to = now
        let wifi = WiFiMonitor.shared.window(from: from, to: to)
        let pauses = sender.stalls(from: ref &- 300_000, to: now)
        let minRssi = wifi.samples.map(\.rssi).filter { $0 < 0 }.min()
        let gapMs = Double(r.gapUs) / 1000
        var cut = false
        var enobufs = 0
        for k in 0..<4 { if let f = sender.sentFrame(r.startFrame &+ UInt32(k)) { cut = cut || f.cut; enobufs += f.enobufs } }

        let cause: Cause
        var why: [String] = []
        if r.trigger == 3 || r.trigger == 4 {
            cause = .windowsBusy
            why.append(r.trigger == 3 ? "decoder lost its references" : "frames piled up faster than Windows showed them")
        } else if cut {
            cause = .macQueue
            why.append("frame cut on the Mac after \(enobufs) full-queue retries")
        } else if r.got == 0 || gapMs >= 50 || !pauses.isEmpty {
            cause = .dropout
            let silent = max(gapMs, pauses.map { Double($0.end - $0.start) / 1000 }.max() ?? 0)
            why.append(String(format: "nothing arrived for %.0f ms", silent))
            if r.got == 0 && r.pkts > 0 { why.append("whole frame missing") }
        } else if r.broken > 0 {
            cause = .burst
            let lostPkts = r.pkts - r.got
            why.append("\(lostPkts) of \(r.pkts) packets lost, \(r.broken) group(s) past repair" + (fecGroup > 0 ? " (1 fix per \(fecGroup))" : " (protection off)"))
            if r.frameBytes > 150_000 { why.append(String(format: "big frame %.0f KB", Double(r.frameBytes) / 1024)) }
        } else {
            cause = .unknown
            why.append("trigger \(r.trigger), \(r.got)/\(r.pkts) packets")
        }
        if let m = minRssi { why.append("signal \(m) dBm" + (m < -70 ? " (weak)" : "")) }
        if let tx = wifi.samples.map(\.txRate).min(), tx > 0 { why.append(String(format: "Wi-Fi rate ≥%.0f Mbps", tx)) }
        why.append(contentsOf: wifi.events)
        // most frames are usually lost waiting for the keyframe, not in the loss itself
        var rec = String(format: "recovery %.0f ms", Double(r.recoverUs) / 1000)
        if r.keyBytes > 0 { rec += String(format: ", keyframe %.0f KB", Double(r.keyBytes) / 1024) }
        if r.keysSeen > 1 { rec += ", keyframe lost \(r.keysSeen - 1)× too" }
        why.append(rec)

        return Event(at: Date(), monitor: monitor, cause: cause, frames: r.frames, recoverMs: Double(r.recoverUs) / 1000,
                     detail: why.joined(separator: "; "), rssi: minRssi, gapMs: gapMs,
                     packets: "\(r.got)/\(r.pkts) (+\(r.parity) parity)", frameKB: Double(r.frameBytes) / 1024,
                     keyKB: Double(r.keyBytes) / 1024, keyTries: max(1, r.keysSeen))
    }
}
