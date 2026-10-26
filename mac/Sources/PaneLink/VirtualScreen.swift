import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

/// A real macOS display backed by nothing: WindowServer composites into it at the requested
/// refresh rate, it shows up in System Settings › Displays and can be arranged like any monitor.
///
/// HiDPI (what BetterDisplay does): macOS renders the desktop at 2× — 5120×2880 for a 1440p
/// monitor — and capture scales it down to the monitor's native resolution, so text is
/// supersampled and sharp instead of 1× (macOS has no subpixel smoothing any more). `uiScale` < 1
/// gives a "looks like" smaller resolution (bigger text) that is still rendered at 2×.
final class VirtualScreen {
    let display: CGVirtualDisplay
    /// What gets captured, encoded and shown on Windows: the monitor's native pixels.
    let width: Int, height: Int, refreshRate: Double
    /// Desktop size in points ("looks like") and the backing pixels macOS renders.
    let pointWidth: Int, pointHeight: Int, pixelWidth: Int, pixelHeight: Int
    let hiDPI: Bool

    var displayID: CGDirectDisplayID { display.displayID }

    /// `serial` must be stable per physical Windows monitor so macOS restores its arrangement.
    init?(name: String, width: Int, height: Int, refreshRate: Double, serial: UInt32, ppi: Double = 109,
          hiDPI: Bool = false, uiScale: Double = 1) {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        let scale = hiDPI ? min(max(uiScale, 0.5), 1) : 1
        let pw = even(Double(width) * scale), ph = even(Double(height) * scale)
        let bw = hiDPI ? pw * 2 : width, bh = hiDPI ? ph * 2 : height

        let desc = CGVirtualDisplayDescriptor()
        desc.setDispatchQueue(DispatchQueue.main)
        desc.name = name
        desc.maxPixelsWide = UInt32(bw)
        desc.maxPixelsHigh = UInt32(bh)
        desc.sizeInMillimeters = CGSize(width: Double(width) / ppi * 25.4, height: Double(height) / ppi * 25.4)
        desc.vendorID = 0x504C   // "PL"
        desc.productID = 0x0001
        desc.serialNum = serial
        desc.terminationHandler = { _, _ in }
        guard let display = CGVirtualDisplay(descriptor: desc) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        // full rate + the low-power rates, so low-power mode can switch without recreating the display.
        // With hiDPI, listing the point size ("looks like") makes macOS add its 2× mode, backed by maxPixels.
        let mw = UInt(hiDPI ? pw : width), mh = UInt(hiDPI ? ph : height)
        var modes = [CGVirtualDisplayMode(width: mw, height: mh, refreshRate: refreshRate)]
        for hz in [60.0, 40, 30] where refreshRate > hz + 1 {
            modes.append(CGVirtualDisplayMode(width: mw, height: mh, refreshRate: hz))
        }
        settings.modes = modes
        guard display.apply(settings) else { return nil }

        self.display = display
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.pointWidth = hiDPI ? pw : width
        self.pointHeight = hiDPI ? ph : height
        self.pixelWidth = bw
        self.pixelHeight = bh
        self.hiDPI = hiDPI
    }

    /// Picks our mode (right "looks like" size, 2× backing when HiDPI) at `hz`. Returns true on success.
    @discardableResult
    func setRefreshRate(_ hz: Double) -> Bool {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode],
              let mode = all.first(where: { $0.width == pointWidth && $0.height == pointHeight && $0.pixelWidth == pixelWidth
                                             && abs($0.refreshRate - hz) < 1 }) else {
            Log.write("virtual display \(displayID): no \(pointWidth)x\(pointHeight) (\(pixelWidth)px) @\(hz) mode")
            return false
        }
        if let cur = CGDisplayCopyDisplayMode(displayID), cur.ioDisplayModeID == mode.ioDisplayModeID { return true }
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayWithDisplayMode(cfg, displayID, mode, nil)
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
    }

    var currentRefreshRate: Double {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return 0 }
        return mode.refreshRate
    }
}
