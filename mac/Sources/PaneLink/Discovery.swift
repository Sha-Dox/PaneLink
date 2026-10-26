import Darwin
import Foundation

/// Finds PaneLink PCs on the LAN: broadcasts "PANELINK?" to UDP 49500 and collects the agents'
/// "PANELINK 1 <port> <MAC> <name>" answers (see PROTOCOL.md).
enum Discovery {
    struct PC: Identifiable, Hashable {
        let name: String, host: String, mac: String
        let port: UInt16
        var id: String { host }
    }

    static func scan(timeout: TimeInterval = 1.5, port: UInt16 = 49500) async -> [PC] {
        await Task.detached { scanBlocking(timeout: timeout, port: port) }.value
    }

    private static func scanBlocking(timeout: TimeInterval, port: UInt16) -> [PC] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        let probe = Array("PANELINK?\n".utf8)
        // limited broadcast leaves on the primary interface only: also each interface's own broadcast address
        var targets = ["255.255.255.255"]
        var ifs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifs) == 0 {
            var p = ifs
            while let i = p {
                let f = Int32(i.pointee.ifa_flags)
                if f & IFF_UP != 0, f & IFF_BROADCAST != 0, f & IFF_LOOPBACK == 0,
                   let ba = i.pointee.ifa_dstaddr, ba.pointee.sa_family == sa_family_t(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ba, socklen_t(ba.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let s = String(cString: host)
                        if !targets.contains(s) { targets.append(s) }
                    }
                }
                p = i.pointee.ifa_next
            }
            freeifaddrs(ifs)
        }
        for t in targets {
            var a = sockaddr_in()
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            inet_pton(AF_INET, t, &a.sin_addr)
            _ = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, probe, probe.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        var found: [PC] = []
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            var tv = timeval(tv_sec: 0, tv_usec: 100_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buf = [UInt8](repeating: 0, count: 512)
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let parts = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", maxSplits: 4).map(String.init)
            guard parts.count >= 5, parts[0] == "PANELINK", let p = UInt16(parts[2]) else { continue }
            var addr = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &addr, socklen_t(addr.count))
            let host = String(cString: addr)
            if !found.contains(where: { $0.host == host }) {
                found.append(PC(name: parts[4], host: host, mac: parts[3] == "-" ? "" : parts[3], port: p))
            }
        }
        Log.write("discovery: \(found.map { "\($0.name)@\($0.host)" })")
        return found
    }
}
