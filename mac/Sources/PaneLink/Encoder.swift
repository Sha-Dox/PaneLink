import CoreMedia
import Foundation
import VideoToolbox

/// Hardware HEVC/H.264 encoder tuned like Sunshine's: real-time, no B-frames, one reference,
/// low-latency rate control, keyframes only on demand. Emits Annex-B access units.
final class Encoder {
    enum Codec: String, CaseIterable, Codable { case hevc, h264 }

    let codec: Codec
    let width: Int, height: Int
    var onFrame: ((UnsafeRawBufferPointer, Bool) -> Void)?
    var diag: Diag?
    private(set) var lowLatencyRC = false

    private var session: VTCompressionSession?
    private var annexB = [UInt8]()
    private let keyLock = NSLock()
    private var wantKey = true
    private var lastKeyUs: UInt64 = 0
    private var framesSinceKey = 0
    /// HEVC POC here is 11 bits. At the 2048 wrap VideoToolbox emits a frame with an empty reference
    /// set that FFmpeg/DXVA can't follow, and every later frame fails to decode (a hard freeze ~17 s in).
    /// A keyframe before the wrap resets the POC so it never happens.
    private let keyEvery = 1900

    // stats (written on encoder thread, read on main)
    private(set) var encodeUsAvg: Double = 0

    init(width: Int, height: Int, fps: Int, bitrateMbps: Int, codec: Codec, fullRange: Bool = false) throws {
        self.codec = codec
        self.width = width
        self.height = height
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264

        func create(lowLatency: Bool) -> VTCompressionSession? {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            ]
            var s: VTCompressionSession?
            let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
                                                encoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            return st == noErr ? s : nil
        }
        // Not EnableLowLatencyRateControl: on the M4 it roughly halves encoder throughput. Measured with
        // 1440p + 1080x1920 at 120 fps: low-latency mode tops out at 81 fps with 12/40 ms latency, the
        // standard real-time mode keeps up at 5-8 ms. No B-frames + MaxFrameDelayCount 0 keep it 1-in-1-out.
        session = create(lowLatency: false)
        guard let s = session else { throw NSError(domain: "PaneLink", code: 1, userInfo: [NSLocalizedDescriptionKey: "No hardware \(codec.rawValue) encoder"]) }

        func set(_ k: CFString, _ v: Any) { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        set(kVTCompressionPropertyKey_ProfileLevel, codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 0)
        set(kVTCompressionPropertyKey_ReferenceBufferCount, 1)
        // Spatial adaptive QP costs ~13% encoder throughput (measured: 127 -> 144 fps for both displays
        // together); at these bitrates the visual difference is negligible, the extra headroom is not.
        if #available(macOS 15.0, *) { set(kVTCompressionPropertyKey_SpatialAdaptiveQPLevel, kVTQPModulationLevel_Disable) }
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        setBitrate(mbps: bitrateMbps)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit {
        if let s = session { VTCompressionSessionInvalidate(s) }
    }

    func setFrameRate(_ fps: Int) {
        guard let s = session else { return }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    }

    func setBitrate(mbps: Int) {
        guard let s = session else { return }
        let bps = mbps * 1_000_000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        // cap any one-second window at 1.5x so a sudden full-screen change can't flood Wi-Fi
        let limits = [Double(bps) * 1.5 / 8, 1.0] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    /// Returns true if a keyframe was actually scheduled (rate-limited to one per 40 ms).
    @discardableResult
    func requestKeyframe(force: Bool = false) -> Bool {
        keyLock.lock(); defer { keyLock.unlock() }
        if !force && nowUs() - lastKeyUs < 40_000 { return false }
        wantKey = true
        return true
    }

    // Latest-frame-wins admission: at most one frame per display inside the (shared) hardware
    // encoder. If a new capture arrives while one is encoding, it replaces any waiting frame instead
    // of queueing behind it, so under full load latency stays bounded and only stale frames are skipped.
    private let gate = NSLock()
    private let emitLock = NSLock()   // annexB buffer + in-order sends if VT ever overlaps callbacks
    private var inFlight = false
    private var waiting: (CVPixelBuffer, CMTime)?

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        gate.lock()
        if inFlight {
            if waiting != nil { diag?.add("skipStale") }
            waiting = (pixelBuffer, pts)
            gate.unlock()
            return
        }
        inFlight = true
        gate.unlock()
        submit(pixelBuffer, pts: pts)
    }

    private func finished() {
        gate.lock()
        guard let next = waiting else { inFlight = false; gate.unlock(); return }
        waiting = nil
        gate.unlock()
        submit(next.0, pts: next.1)
    }

    private func submit(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let s = session else { return }
        keyLock.lock()
        framesSinceKey += 1
        let key = wantKey || framesSinceKey >= keyEvery
        if key { wantKey = false; lastKeyUs = nowUs(); framesSinceKey = 0 }
        keyLock.unlock()
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let t0 = nowUs()
        let st = VTCompressionSessionEncodeFrame(s, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
                                                 frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sbuf in
            guard let self else { return }
            guard status == noErr, let sbuf else { self.diag?.add("vtDrop"); self.finished(); return }
            let dt = Double(nowUs() - t0)
            self.encodeUsAvg = self.encodeUsAvg * 0.9 + dt * 0.1
            self.diag?.max("encMaxMs", dt / 1000)
            self.diag?.add("enc")
            self.diag?.add("encSumMs", dt / 1000)
            // start the next frame first: the hardware encodes it while this one is packetised and sent
            self.finished()
            self.emitLock.lock()
            self.emit(sbuf)
            self.emitLock.unlock()
        }
        if st != noErr { diag?.add("vtErr"); finished() }
    }

    private func emit(_ sbuf: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sbuf), let fmt = CMSampleBufferGetFormatDescription(sbuf) else { return }
        var keyframe = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = atts.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }
        annexB.removeAll(keepingCapacity: true)
        let startCode: [UInt8] = [0, 0, 0, 1]

        if keyframe {
            var count = 0
            var i = 0
            repeat {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let st = codec == .hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                         parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                         parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                guard st == noErr, let ptr else { break }
                annexB += startCode
                annexB.append(contentsOf: UnsafeBufferPointer(start: ptr, count: size))
                i += 1
            } while i < count
        }

        var total = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        var contiguous = block
        if !CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: 0) {
            var out: CMBlockBuffer?
            CMBlockBufferCreateContiguous(allocator: nil, sourceBuffer: block, blockAllocator: nil, customBlockSource: nil,
                                          offsetToData: 0, dataLength: 0, flags: 0, blockBufferOut: &out)
            if let out { contiguous = out }
        }
        guard CMBlockBufferGetDataPointer(contiguous, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &dataPtr) == noErr,
              let dataPtr else { return }
        let raw = UnsafeRawPointer(dataPtr)
        var off = 0
        while off + 4 <= total {
            let n = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
            off += 4
            guard n > 0, off + n <= total else { break }
            annexB += startCode
            annexB.append(contentsOf: UnsafeRawBufferPointer(start: raw + off, count: n))
            off += n
        }
        annexB.withUnsafeBytes { onFrame?($0, keyframe) }
    }
}
