import AppKit
import QuartzCore

/// Fullscreen moving-bar pattern on each Windows display, driven by that display's own display
/// link with plain CALayers (cheap, so it really renders every refresh). Stutter is obvious.
@MainActor
enum TestPattern {
    private static var windows: [NSWindow] = []

    static var isShowing: Bool { !windows.isEmpty }

    static func toggle(on ids: [CGDirectDisplayID]) {
        if isShowing { hide(); return }
        for id in ids {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
            }) else { continue }
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver
            w.isReleasedWhenClosed = false
            let v = PatternView(frame: CGRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            v.startLink()
            windows.append(w)
        }
    }

    static func hide() {
        windows.forEach { ($0.contentView as? PatternView)?.stopLink(); $0.close() }
        windows.removeAll()
    }
}

private final class PatternView: NSView {
    private let bar = CALayer(), hbar = CALayer()
    private let label = CATextLayer()
    private var link: CADisplayLink?
    private let start = CACurrentMediaTime()
    private var ticks = 0, lastLog = CACurrentMediaTime()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.backgroundColor = NSColor.black.cgColor
        bar.backgroundColor = NSColor.white.cgColor
        hbar.backgroundColor = NSColor.cyan.cgColor
        label.foregroundColor = NSColor.green.cgColor
        label.fontSize = 64
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold)
        label.alignmentMode = .center
        [bar, hbar, label].forEach { layer!.addSublayer($0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func startLink() {
        let l = displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }
    func stopLink() { link?.invalidate(); link = nil }

    @objc private func tick(_ l: CADisplayLink) {
        let t = l.targetTimestamp - start
        let size = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // one sweep per second: at 120 Hz the bar jumps width/120 px per frame, evenly
        bar.frame = CGRect(x: CGFloat(t.truncatingRemainder(dividingBy: 1)) * size.width - 20, y: 0, width: 40, height: size.height)
        hbar.frame = CGRect(x: 0, y: CGFloat((t * 0.5).truncatingRemainder(dividingBy: 1)) * size.height - 10, width: size.width, height: 20)
        label.frame = CGRect(x: 0, y: size.height / 2 - 40, width: size.width, height: 80)
        label.string = String(format: "%.3f s", t)
        CATransaction.commit()
        ticks += 1
        let now = CACurrentMediaTime()
        if now - lastLog >= 1 { Log.write("testpattern \(Int(size.width))x\(Int(size.height)) \(ticks) fps"); ticks = 0; lastLog = now }
    }
}
