import AppKit

/// Small live readout on each Windows display (drawn on the Mac side, so it is streamed like
/// everything else). Corner, fields, size and opacity come from Settings › Controls.
@MainActor
enum StatsOverlay {
    private final class Item { let panel: NSPanel; let bg: NSView; let label: NSTextField; let display: CGDirectDisplayID
        init(_ p: NSPanel, _ b: NSView, _ l: NSTextField, _ d: CGDirectDisplayID) { panel = p; bg = b; label = l; display = d } }
    private static var items: [String: Item] = [:]
    private static var timer: Timer?

    /// `displays`: monitor device -> virtual display id.
    static func show(_ displays: [String: CGDirectDisplayID]) {
        hide()
        let prefs = AppState.shared.settings.tuning.overlay
        for (device, id) in displays {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let bg = NSView()
            bg.wantsLayer = true
            bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(prefs.opacity).cgColor
            bg.layer?.cornerRadius = 7
            let label = NSTextField(labelWithString: "…")
            label.font = .monospacedSystemFont(ofSize: prefs.fontSize, weight: .medium)
            label.textColor = .white
            bg.addSubview(label)
            p.contentView = bg
            items[device] = Item(p, bg, label, id)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { refresh() } }
        refresh()
        items.values.forEach { $0.panel.orderFrontRegardless() }
    }

    static func hide() {
        timer?.invalidate(); timer = nil
        items.values.forEach { $0.panel.orderOut(nil) }
        items.removeAll()
    }

    static func text(_ s: StreamStats, _ fields: [OverlayPrefs.Field]) -> String {
        fields.map { f -> String in
            switch f {
            case .fps: String(format: "%3.0f fps", s.fps)
            case .total: String(format: "~%4.1f ms", s.totalMs)
            case .encode: String(format: "enc %.1f", s.encodeMs)
            case .network: String(format: "net %.1f", s.networkMs)
            case .windows: String(format: "win %.1f", s.displayMs)
            case .lost: "lost \(s.lostFrames)"
            case .bitrate: String(format: "%3.0f Mb/s", s.mbps)
            }
        }.joined(separator: "  ")
    }

    private static func refresh() {
        let prefs = AppState.shared.settings.tuning.overlay
        for (device, it) in items {
            let s = AppState.shared.stats[device] ?? StreamStats()
            it.label.stringValue = prefs.fields.isEmpty ? "PaneLink" : text(s, prefs.fields)
            it.label.textColor = Int(s.lostFrames) > prefs.warnLost ? .systemOrange : .white
            it.label.sizeToFit()
            let size = NSSize(width: it.label.frame.width + 16, height: it.label.frame.height + 10)
            it.label.setFrameOrigin(NSPoint(x: 8, y: 5))
            let b = CGDisplayBounds(it.display)
            let x = prefs.corner == .topLeft || prefs.corner == .bottomLeft ? b.minX + 12 : b.maxX - size.width - 12
            let y = prefs.corner == .topLeft || prefs.corner == .topRight ? b.minY + 40 : b.maxY - size.height - 12   // under the menu bar
            let frame = AlignOverlay.cocoaRect(CGRect(x: x, y: y, width: size.width, height: size.height))
            if it.panel.frame != frame { it.panel.setFrame(frame, display: true) }
        }
    }
}
