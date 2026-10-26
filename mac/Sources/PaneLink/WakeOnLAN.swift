import Darwin
import Foundation

/// Magic packet (6×0xFF + 16× the MAC) to the LAN broadcast addresses and the PC itself.
enum WakeOnLAN {
    static func parseMAC(_ s: String) -> [UInt8]? {
        let hex = s.filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }

    @discardableResult
    static func send(mac: String, hosts: [String]) -> Bool {
        guard let m = parseMAC(mac) else { return false }
        var pkt = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { pkt += m }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        // limited broadcast, each LAN host's /24 broadcast, and the host itself (works if its ARP entry is cached)
        var targets = ["255.255.255.255"]
        for h in hosts where h.hasPrefix("192.168.") || h.hasPrefix("10.") || h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count == 4 { targets.append(parts.prefix(3).joined(separator: ".") + ".255") }
            targets.append(h)
        }
        var sent = false
        for t in targets {
            for port: UInt16 in [9, 7] {
                var a = sockaddr_in()
                a.sin_family = sa_family_t(AF_INET)
                a.sin_port = port.bigEndian
                inet_pton(AF_INET, t, &a.sin_addr)
                let n = withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                sent = sent || n == pkt.count
            }
        }
        Log.write("wake-on-LAN \(mac) -> \(targets): \(sent ? "sent" : "failed")")
        return sent
    }
}
