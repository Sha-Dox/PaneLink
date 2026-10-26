import Darwin
import Foundation

/// Packetizes Annex-B frames into UDP datagrams with interleaved XOR parity (see PROTOCOL.md)
/// and receives viewer feedback on the same socket.
final class VideoSender {
    static let payload = 1400
    static let header = 20

    enum Feedback {
        case keyframeRequest
        case stats(echoTs: UInt32, holdUs: UInt32, ok: UInt32, lost: UInt32, decodeUs: UInt32, presentUs: UInt32, ageUs: UInt32?)
        case loss(LossReport)
    }

    /// What we sent for one frame, kept for a few seconds so a loss report can be matched to it.
    struct SentFrame {
        var fno: UInt32, sentUs: UInt64, durUs: UInt32, bytes: Int, packets: Int, key: Bool, cut: Bool, enobufs: Int
    }
    private static let ringSize = 1024
    private var ring = [SentFrame?](repeating: nil, count: VideoSender.ringSize)
    private let ringLock = NSLock()
    private var frameEnobufs = 0
    private var stalls: [(start: UInt64, end: UInt64)] = []   // recent pauses (link looked dead)

    func sentFrame(_ fno: UInt32) -> SentFrame? {
        ringLock.lock(); defer { ringLock.unlock() }
        let f = ring[Int(fno % UInt32(Self.ringSize))]
        return f?.fno == fno ? f : nil
    }

    /// Pauses (heartbeat silence) that overlap [from, to].
    func stalls(from: UInt64, to: UInt64) -> [(start: UInt64, end: UInt64)] {
        stallLock.lock(); defer { stallLock.unlock() }
        var out = stalls.filter { $0.end >= from && $0.start <= to }
        if inStall && stallStartUs <= to { out.append((stallStartUs, nowUs())) }
        return out
    }

    var groupSize: Int  // data packets per parity packet; 0 disables FEC
    var onFeedback: ((Feedback) -> Void)?
    var diag: Diag?

    private let fd: Int32
    private var frameNo: UInt32 = 0
    private var packet = [UInt8](repeating: 0, count: VideoSender.header + VideoSender.payload)
    private var parity = [UInt8]()
    private var readSource: DispatchSourceRead?
    private(set) var bytesSent: UInt64 = 0
    private(set) var framesSent: UInt64 = 0
    private(set) var lastFrameSentUs: UInt64 = 0

    // Blackout handling. Viewers that send heartbeats (0x12, every 20 ms) let us notice a dead link
    // within ~120 ms. While it's dead we stop sending: frames would only pile up in the Wi-Fi queue and
    // arrive stale after it recovers. The first heartbeat back triggers `onResume` (send a keyframe now
    // instead of waiting for the viewer to discover the gap and ask).
    var onResume: (() -> Void)?
    private let stallLock = NSLock()
    private var lastFeedbackUs: UInt64 = 0
    private var heartbeats = false
    private var inStall = false
    private var stallStartUs: UInt64 = 0
    var stallAfterUs: UInt64 = 120_000

    /// True while the link looks dead (only for viewers that send heartbeats).
    var stalled: Bool {
        stallLock.lock(); defer { stallLock.unlock() }
        return heartbeats && nowUs() - lastFeedbackUs > stallAfterUs
    }

    // ENOBUFS waits per frame are capped: past this the rest of the frame is dropped (the viewer asks
    // for a keyframe) instead of stalling the encoder thread for up to hundreds of ms.
    private var enobufsBudgetUs = 0
    private var frameCut = false

    init?(host: String, port: UInt16, groupSize: Int) {
        self.groupSize = groupSize
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var sndbuf: Int32 = 8 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))
        var tos: Int32 = 0xA0  // DSCP CS5 -> Wi-Fi WMM video access category
        setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { close(fd); return nil }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { close(fd); return nil }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        src.setEventHandler { [weak self] in self?.readFeedback() }
        src.resume()
        readSource = src
    }

    deinit {
        readSource?.cancel()
        close(fd)
    }

    private func readFeedback() {
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let n = recv(fd, &buf, buf.count, MSG_DONTWAIT)
            if n <= 0 { return }
            stallLock.lock()
            let t = nowUs()
            if buf[0] == 0x12 { heartbeats = true }
            let resumed = inStall
            if resumed {
                diag?.max("stallMs", Double(t - stallStartUs) / 1000)
                stalls.append((stallStartUs, t)); if stalls.count > 32 { stalls.removeFirst() }
            }
            inStall = false
            lastFeedbackUs = t
            stallLock.unlock()
            if resumed { onResume?() }
            buf.withUnsafeBytes { raw in
                func u32(_ off: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)) }
                switch raw[0] {
                case 0x10 where n >= 8: onFeedback?(.keyframeRequest)
                case 0x12: break   // heartbeat, handled above
                case 0x13 where n >= 40:
                    func u16(_ off: Int) -> Int { Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))) }
                    onFeedback?(.loss(LossReport(trigger: Int(raw[1]), startFrame: u32(4), frames: Int(u32(8)), pkts: u16(12), got: u16(14),
                                                 parity: u16(16), broken: u16(18), gapUs: Int(u32(20)), recoverUs: Int(u32(24)),
                                                 idrReqs: u16(28), keysSeen: u16(30), frameBytes: Int(u32(32)), keyBytes: Int(u32(36)))))
                case 0x11 where n >= 28:
                    // newer viewers append how long ago the echoed frame was shown (screen idle time)
                    onFeedback?(.stats(echoTs: u32(4), holdUs: u32(8), ok: u32(12), lost: u32(16), decodeUs: u32(20), presentUs: u32(24),
                                       ageUs: n >= 32 ? u32(28) : nil))
                default: break
                }
            }
        }
    }

    /// Sends a small out-of-band datagram (e.g. color settings) on the video socket.
    func sendControl(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
    }

    /// Sends one encoded access unit. Called from the encoder's output thread only.
    func send(frame: UnsafeRawBufferPointer, keyframe: Bool, timestampUs: UInt32) {
        let p = VideoSender.payload, h = VideoSender.header
        let len = frame.count
        let count = max(1, (len + p - 1) / p)
        let group = groupSize > 0 ? groupSize : Int(UInt16.max)
        let ngroups = groupSize > 0 ? (count + group - 1) / group : 0
        let sendStart = nowUs()
        // dead link: drop (and don't burn a frame number, so the viewer sees one clean gap)
        stallLock.lock()
        let dead = heartbeats && sendStart - lastFeedbackUs > stallAfterUs
        if dead && !inStall { inStall = true; stallStartUs = sendStart; diag?.add("stalls") }
        stallLock.unlock()
        if dead { diag?.add("stallDrop"); return }
        let fno = frameNo
        frameNo &+= 1
        enobufsBudgetUs = 3000
        frameCut = false
        frameEnobufs = 0

        if ngroups > 0 {
            if parity.count < ngroups * p { parity = [UInt8](repeating: 0, count: ngroups * p) }
            parity.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, ngroups * p) }
        }

        packet.withUnsafeMutableBytes { pkt in
            let base = pkt.baseAddress!
            func header(type: UInt8, index: Int) {
                pkt[0] = type
                pkt[1] = keyframe ? 1 : 0
                pkt.storeBytes(of: UInt16(index).littleEndian, toByteOffset: 2, as: UInt16.self)
                pkt.storeBytes(of: fno.littleEndian, toByteOffset: 4, as: UInt32.self)
                pkt.storeBytes(of: UInt16(count).littleEndian, toByteOffset: 8, as: UInt16.self)
                pkt.storeBytes(of: UInt16(min(group, Int(UInt16.max))).littleEndian, toByteOffset: 10, as: UInt16.self)
                pkt.storeBytes(of: UInt32(len).littleEndian, toByteOffset: 12, as: UInt32.self)
                pkt.storeBytes(of: timestampUs.littleEndian, toByteOffset: 16, as: UInt32.self)
            }
            for i in 0..<count {
                let off = i * p
                let n = min(p, len - off)
                header(type: 1, index: i)
                memcpy(base + h, frame.baseAddress! + off, n)
                if !frameCut { transmit(base, h + n) }
                if ngroups > 0 {
                    parity.withUnsafeMutableBytes { par in
                        xor(into: par.baseAddress! + (i % ngroups) * p, from: frame.baseAddress! + off, count: n)
                    }
                }
            }
            for g in 0..<ngroups {
                header(type: 2, index: g)
                parity.withUnsafeBytes { memcpy(base + h, $0.baseAddress! + g * p, p) }
                if !frameCut { transmit(base, h + p) }
            }
        }
        framesSent += 1
        lastFrameSentUs = nowUs()
        ringLock.lock()
        ring[Int(fno % UInt32(Self.ringSize))] = SentFrame(fno: fno, sentUs: sendStart, durUs: UInt32(lastFrameSentUs - sendStart), bytes: len,
                                                            packets: count + ngroups, key: keyframe, cut: frameCut, enobufs: frameEnobufs)
        ringLock.unlock()
        diag?.max("sendMaxMs", Double(nowUs() - sendStart) / 1000)
        diag?.max("maxFrameKB", Double(len) / 1024)
        if keyframe { diag?.add("keys") }
    }

    private func transmit(_ ptr: UnsafeRawPointer, _ n: Int) {
        // ENOBUFS means the Wi-Fi driver queue is momentarily full: back off a hair and retry,
        // within the frame's budget
        while true {
            if Darwin.send(fd, ptr, n, 0) >= 0 { bytesSent += UInt64(n); return }
            if errno != ENOBUFS && errno != EAGAIN { diag?.add("sendErr"); return }
            diag?.add("enobufs")
            frameEnobufs += 1
            if enobufsBudgetUs <= 0 { frameCut = true; diag?.add("frameCut"); return }
            usleep(20)
            enobufsBudgetUs -= 20
        }
    }

    private func xor(into dst: UnsafeMutableRawPointer, from src: UnsafeRawPointer, count n: Int) {
        var i = 0
        while i + 8 <= n {
            let a = dst.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            let b = src.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            dst.storeBytes(of: a ^ b, toByteOffset: i, as: UInt64.self)
            i += 8
        }
        while i < n {
            dst.storeBytes(of: dst.load(fromByteOffset: i, as: UInt8.self) ^ src.load(fromByteOffset: i, as: UInt8.self), toByteOffset: i, as: UInt8.self)
            i += 1
        }
    }
}

@inline(__always) func nowUs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000 }
