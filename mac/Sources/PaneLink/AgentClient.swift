import Foundation
import Network

struct RemoteMonitor: Identifiable, Hashable, Codable {
    var index: Int
    var x: Int, y: Int, width: Int, height: Int, refreshRate: Int
    var primary: Bool
    var device: String
    var name: String

    var id: String { device }

    /// Stable per physical monitor so macOS remembers where the virtual display was arranged.
    var serial: UInt32 {
        var h: UInt32 = 2166136261
        for b in (name + device).utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h
    }
}

/// Line-based TCP control channel to the Windows agent (see PROTOCOL.md).
final class AgentClient {
    enum Event {
        case connected(host: String)
        case monitors([RemoteMonitor])
        case ok(Int)
        case error(Int, String)
        case stoppedByRemote(String)
        case fansReady(Bool)
        case rest(on: Bool, paused: Int, running: Int)
        case needsPairing                 // this PC doesn't know us (no token, or it was forgotten)
        case pairing                      // the code is on the PC's screens now
        case paired(token: String)
        case pairFailed(String)           // wrong / expired / wait
        case disconnected(String?)
    }

    var onEvent: ((Event) -> Void)?
    private(set) var host: String?

    private var conn: NWConnection?
    private var buffer = Data()
    private var pending: [RemoteMonitor] = []
    private var expectMonitors = 0
    private var pingTimer: Timer?
    private var attempt = 0
    private var token = ""

    /// Tries each host in order (LAN first, Tailscale fallback) with a short timeout.
    func connect(hosts: [String], token: String, port: UInt16 = 49500) {
        disconnect()
        attempt += 1
        self.token = token
        guard !hosts.isEmpty else { onEvent?(.disconnected("No Windows PC set up")); return }
        tryHost(hosts, at: 0, port: port, attempt: attempt)
    }

    private func tryHost(_ hosts: [String], at i: Int, port: UInt16, attempt: Int) {
        guard attempt == self.attempt else { return }
        guard i < hosts.count else { onEvent?(.disconnected("Windows agent not reachable")); return }
        let host = hosts[i]
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 2
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
        var settled = false
        // .waiting is often transient right after launch / a Wi-Fi change: give the LAN a real 2 s
        // before falling back to the next (Tailscale) address.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, attempt == self.attempt, !settled else { return }
            settled = true
            c.cancel()
            self.tryHost(hosts, at: i + 1, port: port, attempt: attempt)
        }
        c.stateUpdateHandler = { [weak self] state in
            guard let self, attempt == self.attempt else { return }
            switch state {
            case .ready:
                settled = true
                self.conn = c
                self.host = host
                self.receive(on: c)
                self.onEvent?(.connected(host: host))
                if !self.token.isEmpty { self.send("AUTH \(self.token)") }   // older agents ignore it
                self.send("HELLO 1")
                self.pingTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.send("PING") }
            case .failed:
                if !settled {
                    settled = true
                    c.cancel()
                    self.tryHost(hosts, at: i + 1, port: port, attempt: attempt)
                } else if self.conn === c {
                    self.dropped("Connection lost")
                }
            case .cancelled:
                if self.conn === c { self.dropped(nil) }
            default: break
            }
        }
        c.start(queue: .main)
    }

    func disconnect() {
        attempt += 1
        pingTimer?.invalidate()
        pingTimer = nil
        conn?.cancel()
        conn = nil
        host = nil
        buffer.removeAll()
    }

    private func dropped(_ reason: String?) {
        disconnect()
        onEvent?(.disconnected(reason))
    }

    var isConnected: Bool { conn != nil }

    func send(_ line: String) {
        conn?.send(content: (line + "\n").data(using: .utf8), completion: .contentProcessed { _ in })
    }

    /// Last field is a power bitmask: 1 = quiet fans, 2 = GPU low power (older agents read it as quiet fans 0/1).
    func start(index: Int, width: Int, height: Int, hz: Int, codec: Encoder.Codec, port: UInt16, vsync: Bool, autoStop: Bool,
               quietFans: Bool, gpuLowPower: Bool, tuning: Tuning, covered: Insets = Insets()) {
        let power = (quietFans ? 1 : 0) | (gpuLowPower ? 2 : 0)
        // then: auto-off mouse px (0 = ignore mouse), auto-off grace ms, GPU cap MHz (older agents ignore extras)
        send("START \(index) \(width) \(height) \(hz) \(codec.rawValue) \(port) \(vsync ? 1 : 0) \(autoStop ? 1 : 0) \(power)"
             + " \(tuning.autoStopMousePx) \(Int(tuning.autoStopGraceSec * 1000)) \(tuning.gpuCapMHz)"
             + " \(covered.left) \(covered.top) \(covered.right) \(covered.bottom)")   // panel area kept black
    }

    func stopAll() { send("STOPALL") }

    /// Asks the PC to show a pairing code; `submit` sends it back.
    func pair(name: String) { send("PAIR \(name)") }
    func submit(code: String) { send("PAIRCODE \(code)") }

    /// After pairing on this same connection: authenticate and fetch the monitors.
    func authenticate(_ token: String) {
        self.token = token
        send("AUTH \(token)")
        send("HELLO 1")
    }

    /// Rest: Windows pauses every app except PaneLink (and what the desktop/fans need) while extending.
    func rest(_ on: Bool, keep: String) {
        let k = keep.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        send(on ? "REST 1" + (k.isEmpty ? "" : " " + k.joined(separator: ",")) : "REST 0")
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, self.conn === c else { return }
            if let data { self.buffer.append(data); self.drainLines() }
            if done || err != nil { self.dropped(err.map { "\($0)" } ?? "Windows closed the connection"); return }
            self.receive(on: c)
        }
    }

    private func drainLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let cmd = parts.first else { return }
        switch cmd {
        case "MONITORS":
            expectMonitors = Int(parts[safe: 1] ?? "") ?? 0
            pending = []
            if expectMonitors == 0 { onEvent?(.monitors([])) }
        case "MON" where parts.count >= 9:
            let n = parts.dropFirst().prefix(7).compactMap { Int($0) }
            guard n.count == 7 else { return }
            let name = parts.count > 9 ? parts[9...].joined(separator: " ") : parts[8]
            pending.append(RemoteMonitor(index: n[0], x: n[1], y: n[2], width: n[3], height: n[4], refreshRate: n[5],
                                         primary: n[6] != 0, device: parts[8], name: name))
            if pending.count == expectMonitors { onEvent?(.monitors(pending)) }
        case "OK": onEvent?(.ok(Int(parts[safe: 1] ?? "") ?? -1))
        case "ERR": onEvent?(.error(Int(parts[safe: 1] ?? "") ?? -1, parts.dropFirst(2).joined(separator: " ")))
        case "STOPPED": onEvent?(.stoppedByRemote(parts[safe: 1] ?? ""))
        case "FANS": onEvent?(.fansReady(parts[safe: 1] == "1"))
        case "AUTH" where parts[safe: 1] == "0", "NEEDPAIR": onEvent?(.needsPairing)
        case "PAIRING": onEvent?(.pairing)
        case "PAIRED": if let t = parts[safe: 1] { onEvent?(.paired(token: t)) }
        case "PAIRFAIL": onEvent?(.pairFailed(parts[safe: 1] ?? ""))
        case "REST": onEvent?(.rest(on: parts[safe: 1] == "1", paused: Int(parts[safe: 2] ?? "") ?? 0, running: Int(parts[safe: 3] ?? "") ?? 0))
        default: break
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
