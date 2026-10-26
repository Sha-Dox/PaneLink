import CoreMedia
import Foundation
import ScreenCaptureKit

struct StreamStats: Equatable {
    var fps: Double = 0
    var mbps: Double = 0
    var encodeMs: Double = 0
    var networkMs: Double = 0       // one-way estimate (rtt / 2)
    var decodeMs: Double = 0
    var displayMs: Double = 0       // viewer: last packet in -> Present returned
    var lostFrames: UInt32 = 0
    var refreshRate: Double = 0

    /// Rough glass-to-glass excluding scan-out: half a capture interval + encode + network + viewer.
    var totalMs: Double { (refreshRate > 0 ? 500 / refreshRate : 0) + encodeMs + networkMs + displayMs }
}

/// One Windows monitor: virtual display -> ScreenCaptureKit -> VideoToolbox -> UDP.
final class StreamSession: NSObject, SCStreamOutput, SCStreamDelegate {
    let monitor: RemoteMonitor
    let screen: VirtualScreen
    let encoder: Encoder
    let sender: VideoSender
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "panelink.capture", qos: .userInteractive)
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPTS = CMTime.zero
    private var lastCaptureUs: UInt64 = 0
    private let fullRange: Bool
    private(set) var lowPower = false
    private(set) var lowPowerFps = 60.0
    private var color = ColorSettings()
    private var colorTimer: DispatchSourceTimer?
    let diag = Diag()
    static let noEncode = CommandLine.arguments.contains("--noencode")
    private var diagTick = 0
    private var loggedFormat = false
    private var lostHistory: [(UInt64, UInt32)] = []   // (time, cumulative lost) for a 10 s window
    private var idleKeyTimer: DispatchSourceTimer?

    private let statsLock = NSLock()
    private var rttUs: Double = -1   // last trustworthy round-trip sample
    private var viewer = (echoTs: UInt32(0), holdUs: UInt32(0), lost: UInt32(0), decodeUs: UInt32(0), at: UInt64(0))
    private var lastSample = (time: nowUs(), frames: UInt64(0), bytes: UInt64(0))

    init(monitor: RemoteMonitor, screen: VirtualScreen, host: String, port: UInt16, settings: Settings, bitrateMbps: Int) throws {
        self.monitor = monitor
        self.screen = screen
        fullRange = settings.fullRange
        encoder = try Encoder(width: screen.width, height: screen.height, fps: Int(screen.refreshRate.rounded()),
                              bitrateMbps: bitrateMbps, codec: settings.codec, fullRange: settings.fullRange)
        guard let s = VideoSender(host: host, port: port, groupSize: settings.fecGroup) else {
            throw NSError(domain: "PaneLink", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't open UDP socket to \(host):\(port)"])
        }
        sender = s
        super.init()

        encoder.diag = diag
        sender.diag = diag
        // PANELINK_DUMP=/dir writes each stream's exact bitstream for offline analysis
        let dump: FileHandle? = ProcessInfo.processInfo.environment["PANELINK_DUMP"].flatMap { dir in
            let path = "\(dir)/\(monitor.device.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: ".", with: "")).\(settings.codec.rawValue)"
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
        encoder.onFrame = { [sender] data, key in
            sender.send(frame: data, keyframe: key, timestampUs: UInt32(truncatingIfNeeded: nowUs()))
            dump?.write(Data(data))
        }
        sender.onResume = { [weak self] in
            guard let self else { return }
            self.diag.add("resumeKey")
            if self.encoder.requestKeyframe(force: true) { self.queue.async { self.reencodeLast() } }
        }
        sender.onFeedback = { [weak self] fb in
            guard let self else { return }
            switch fb {
            case .keyframeRequest:
                // Screen may be idle (no new frames from SCK), so re-encode the last picture now.
                self.diag.add("idrReq")
                if self.encoder.requestKeyframe() {
                    self.queue.async { self.reencodeLast() }
                }
            case let .loss(r):
                let ev = LossLog.classify(r, monitor: self.monitor.name, sender: self.sender, fecGroup: self.sender.groupSize)
                DispatchQueue.main.async { LossLog.shared.add(ev) }
            case let .stats(echoTs, holdUs, _, lost, decodeUs, _, ageUs):
                let t = nowUs()
                // rtt = now - frame sent - time the viewer spent on it - time since it was shown.
                // Without the viewer's age (older builds) only trust samples taken right after a frame.
                let age = ageUs ?? 0
                let rttUs = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: t) &- echoTs &- holdUs &- age))
                let fresh = ageUs != nil || t - self.sender.lastFrameSentUs < 30_000
                self.statsLock.lock()
                self.viewer = (echoTs, holdUs, lost, decodeUs, t)
                if fresh && rttUs >= 0 && rttUs < 2_000_000 { self.rttUs = Double(rttUs) }
                self.statsLock.unlock()
            }
        }
    }

    private func makeConfig(fps: Double) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        cfg.width = screen.width
        cfg.height = screen.height
        // Not 1/refresh: compositor frames jitter around the interval, and any frame that lands a hair
        // early gets dropped (we measured 81 of 120 fps). Half the interval lets every frame through.
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps.rounded() * 2))
        // straight into the encoder, no conversion
        cfg.pixelFormat = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = 5
        cfg.showsCursor = true
        cfg.capturesAudio = false
        cfg.scalesToFit = false
        return cfg
    }

    func start(lowPower: Bool, lowPowerFps: Int = 60, stallMs: Int = 120) async throws {
        let display = try await Self.findDisplay(screen.displayID)
        self.lowPower = lowPower
        self.lowPowerFps = min(Double(lowPowerFps), screen.refreshRate)
        sender.stallAfterUs = UInt64(max(40, stallMs)) * 1000
        let fps = lowPower ? self.lowPowerFps : screen.refreshRate
        screen.setRefreshRate(fps)   // the display may come up in any of its modes
        if lowPower { encoder.setFrameRate(Int(fps)) }
        let cfg = makeConfig(fps: fps)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        WiFiMonitor.shared.retain()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        // color settings ride on the video socket; resend every second so a restarted viewer gets them
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in self?.sendColor() }
        t.resume()
        colorTimer = t
        Log.write("[\(monitor.name)] capture started \(screen.width)x\(screen.height)@\(screen.refreshRate) display \(screen.displayID) screenAccess=\(CGPreflightScreenCaptureAccess())")
    }

    func setTuning(lowPowerFps: Int, stallMs: Int) {
        sender.stallAfterUs = UInt64(max(40, stallMs)) * 1000
        let f = min(Double(lowPowerFps), screen.refreshRate)
        guard f != self.lowPowerFps else { return }
        self.lowPowerFps = f
        if lowPower { lowPower = false; setLowPower(true) }   // re-apply at the new rate
    }

    /// Low power: lower-rate virtual display + capture/encode (a fraction of the GPU and encoder work).
    func setLowPower(_ on: Bool) {
        guard on != lowPower, let stream else { return }
        lowPower = on
        let fps = on ? lowPowerFps : screen.refreshRate
        screen.setRefreshRate(fps)
        encoder.setFrameRate(Int(fps))
        let cfg = makeConfig(fps: fps)
        Task { try? await stream.updateConfiguration(cfg) }
        Log.write("[\(monitor.name)] low power \(on ? "on" : "off"): \(Int(fps)) fps")
    }

    func setColor(_ c: ColorSettings) {
        queue.async { self.color = c; self.sendColor() }
    }

    private func sendColor() {
        var b = [UInt8](repeating: 0, count: 32)
        b[0] = 3
        b[1] = fullRange ? 1 : 0
        let t = color.tint
        let vals: [Float] = [Float(color.brightness), Float(color.contrast), Float(color.saturation), Float(color.gamma), t.0, t.1, t.2]
        b.withUnsafeMutableBytes { raw in
            for (i, v) in vals.enumerated() { raw.storeBytes(of: v.bitPattern.littleEndian, toByteOffset: 4 + i * 4, as: UInt32.self) }
        }
        sender.sendControl(b)
    }

    func stop() {
        if stream != nil { WiFiMonitor.shared.release() }
        colorTimer?.cancel()
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    private static func findDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<40 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let d = content.displays.first(where: { $0.displayID == id }) {
                return d
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "PaneLink", code: 3, userInfo: [NSLocalizedDescriptionKey: "Virtual display didn't appear (Screen Recording permission?)"])
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { diag.add("capNoStatus"); return }
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { diag.add("cap_\(raw)"); return }
        let t = nowUs()
        if lastCaptureUs != 0 { diag.max("capGapMs", Double(t - lastCaptureUs) / 1000) }
        lastCaptureUs = t
        diag.add("cap")
        lastPixelBuffer = pb
        if !loggedFormat {
            loggedFormat = true
            let atts = CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any] ?? [:]
            Log.write("[\(monitor.name)] frame fmt=\(CVPixelBufferGetPixelFormatType(pb)) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) bpr=\(CVPixelBufferGetBytesPerRowOfPlane(pb, 0)) atts=\(atts.filter { !$0.key.contains("ICC") })")
        }
        lastPTS = CMSampleBufferGetPresentationTimeStamp(sb)
        if Self.noEncode { return }   // diagnostics: capture only
        if sender.stalled { diag.add("stallSkip"); return }   // nothing gets through: don't spend encoder time
        encoder.encode(pb, pts: lastPTS)
    }

    private func reencodeLast() {
        guard let pb = lastPixelBuffer else { return }
        lastPTS = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000))
        encoder.encode(pb, pts: lastPTS)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }

    // MARK: stats

    func sampleStats() -> StreamStats {
        let now = nowUs()
        let frames = sender.framesSent, bytes = sender.bytesSent
        let dt = Double(now - lastSample.time) / 1e6
        var s = StreamStats()
        if dt > 0 {
            s.fps = Double(frames - lastSample.frames) / dt
            s.mbps = Double(bytes - lastSample.bytes) * 8 / dt / 1e6
        }
        lastSample = (now, frames, bytes)
        s.encodeMs = encoder.encodeUsAvg / 1000
        s.refreshRate = screen.currentRefreshRate
        statsLock.lock()
        let v = viewer
        statsLock.unlock()
        if v.at != 0 && now - v.at < 3_000_000 {
            statsLock.lock(); let rtt = rttUs; statsLock.unlock()
            s.networkMs = rtt >= 0 ? rtt / 2000 : 0
            s.displayMs = Double(v.holdUs) / 1000
            s.decodeMs = Double(v.decodeUs) / 1000
            lostHistory.append((now, v.lost))
            lostHistory.removeAll { now - $0.0 > 10_000_000 }
            s.lostFrames = v.lost &- (lostHistory.first?.1 ?? v.lost)
        }
        diagTick += 1
        if diagTick % 2 == 0 {
            let d = diag.drain()
            let keys = d.keys.sorted().map { k in "\(k)=\(String(format: "%.1f", d[k]!))" }
            Log.write("[\(monitor.name)] hz=\(String(format: "%.0f", s.refreshRate)) " + keys.joined(separator: " ")
                      + String(format: " net=%.1fms hold=%.1fms lost=%u", s.networkMs, s.displayMs, s.lostFrames))
        }
        return s
    }
}
