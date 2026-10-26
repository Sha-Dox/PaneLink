import AppKit

/// On-screen notch editor for one shared edge: a strip along the edge on both displays with two
/// draggable notch lines each. Drag notch 1 (orange) on both screens until the lines meet across the
/// bezel, then notch 2 (blue) the same way. The cursor uses the new alignment immediately.
@MainActor
final class AlignOverlay {
    static var current: AlignOverlay?

    private var panels: [NSPanel] = []
    private var link: CursorAligner.Link
    private let onChange: (CursorAligner.Link) -> Void
    private var keyMonitor: Any?

    static func show(_ link: CursorAligner.Link, onChange: @escaping (CursorAligner.Link) -> Void) {
        current?.close()
        let o = AlignOverlay(link: link, onChange: onChange)
        current = o
        o.open()
    }

    static func closeAll() { current?.close() }
    static var currentLinkID: String? { current?.link.id }

    private init(link: CursorAligner.Link, onChange: @escaping (CursorAligner.Link) -> Void) {
        self.link = link
        self.onChange = onChange
    }

    private func open() {
        let thick: CGFloat = 240
        for isA in [true, false] {
            let d = isA ? link.a : link.b
            let f = d.frame
            // strip on the shared edge (CG coordinates)
            let strip: CGRect
            if link.vertical { strip = isA ? CGRect(x: f.maxX - thick, y: f.minY, width: thick, height: f.height)
                                           : CGRect(x: f.minX, y: f.minY, width: thick, height: f.height) }
            else { strip = isA ? CGRect(x: f.minX, y: f.maxY - thick, width: f.width, height: thick)
                               : CGRect(x: f.minX, y: f.minY, width: f.width, height: thick) }
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == d.id }
            let panel = KeyPanel(contentRect: Self.cocoaRect(strip), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false, screen: screen)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = NotchView(frame: NSRect(origin: .zero, size: strip.size))
            view.vertical = link.vertical
            view.edgeAtMax = isA            // a's edge is its right/bottom side
            view.fractions = isA ? [link.a1, link.a2] : [link.b1, link.b2]
            view.onDrag = { [weak self] i, v in self?.update(isA: isA, notch: i, value: v) }
            view.onDone = { [weak self] in self?.close() }
            panel.contentView = view
            panel.setFrame(Self.cocoaRect(strip), display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        panels.first?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }   // Esc
            return e
        }
    }

    private func update(isA: Bool, notch: Int, value: Double) {
        let v = min(max(value, 0), 1)
        switch (isA, notch) {
        case (true, 0): link.a1 = v
        case (true, _): link.a2 = v
        case (false, 0): link.b1 = v
        case (false, _): link.b2 = v
        }
        onChange(link)
    }

    func close() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        if AlignOverlay.current === self { AlignOverlay.current = nil }
    }

    /// CG global (top-left origin, y down) -> Cocoa global (bottom-left of the primary screen, y up).
    static func cocoaRect(_ r: CGRect) -> NSRect {
        let h = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class NotchView: NSView {
    var vertical = true          // shared edge is vertical -> notches are horizontal lines
    var edgeAtMax = true         // the shared edge is on the right (vertical) / bottom (horizontal) of this strip
    var fractions: [Double] = [0.1, 0.9]
    var onDrag: ((Int, Double) -> Void)?
    var onDone: (() -> Void)?

    private var dragging: Int?
    private var selected = 0
    private let colors: [NSColor] = [.systemOrange, .systemCyan]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var length: CGFloat { vertical ? bounds.height : bounds.width }
    private func pos(_ i: Int) -> CGFloat { CGFloat(fractions[i]) * length }
    private var doneRect: NSRect {
        let s = NSSize(width: 70, height: 28)
        return vertical ? NSRect(x: (bounds.width - s.width) / 2, y: bounds.height / 2 - 14, width: s.width, height: s.height)
                        : NSRect(x: bounds.width / 2 - 35, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }

    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        bounds.fill()
        // the shared edge itself
        NSColor.white.withAlphaComponent(0.9).setFill()
        let edge: NSRect = vertical ? NSRect(x: edgeAtMax ? bounds.maxX - 3 : 0, y: 0, width: 3, height: bounds.height)
                                    : NSRect(x: 0, y: edgeAtMax ? bounds.maxY - 3 : 0, width: bounds.width, height: 3)
        edge.fill()
        // ruler every 50 pt (longer every 250)
        NSColor.white.withAlphaComponent(0.35).setFill()
        var t: CGFloat = 0
        while t < length {
            let l: CGFloat = Int(t) % 250 == 0 ? 24 : 10
            let r: NSRect = vertical ? NSRect(x: edgeAtMax ? bounds.maxX - 3 - l : 3, y: t, width: l, height: 1)
                                     : NSRect(x: t, y: edgeAtMax ? bounds.maxY - 3 - l : 3, width: 1, height: l)
            r.fill(); t += 50
        }
        for i in 0..<fractions.count {
            let p = pos(i)
            colors[i].setFill()
            let w: CGFloat = i == selected ? 3 : 2
            (vertical ? NSRect(x: 0, y: p - w / 2, width: bounds.width, height: w)
                      : NSRect(x: p - w / 2, y: 0, width: w, height: bounds.height)).fill()
            // handle away from the edge
            let hp = min(max(p, 14), length - 14)   // keep the handle on screen at the very ends
            let c: NSPoint = vertical ? NSPoint(x: edgeAtMax ? 22 : bounds.width - 22, y: hp)
                                      : NSPoint(x: hp, y: edgeAtMax ? 22 : bounds.height - 22)
            NSBezierPath(ovalIn: NSRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26)).fill()
            let label = NSAttributedString(string: "\(i + 1)", attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.black])
            label.draw(at: NSPoint(x: c.x - 4.5, y: c.y - 9))
        }
        let help = "Drag ① and ② on both screens\nso the lines meet across the bezel.\n↑↓ nudge · Tab switch · Esc done"
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white, .paragraphStyle: para]
        let hr: NSRect = vertical ? NSRect(x: 10, y: bounds.height / 2 + 24, width: bounds.width - 20, height: 60)
                                  : NSRect(x: bounds.width / 2 + 50, y: bounds.height / 2 - 26, width: 240, height: 60)
        (help as NSString).draw(in: hr, withAttributes: attrs)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: doneRect, xRadius: 6, yRadius: 6).fill()
        let done = NSAttributedString(string: "Done", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.black])
        done.draw(at: NSPoint(x: doneRect.midX - done.size().width / 2, y: doneRect.midY - done.size().height / 2))
    }

    private func along(_ e: NSEvent) -> CGFloat {
        let p = convert(e.locationInWindow, from: nil)
        return vertical ? p.y : p.x
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeKey()
        if doneRect.contains(convert(e.locationInWindow, from: nil)) { onDone?(); return }
        let a = along(e)
        let nearest = (0..<fractions.count).min { abs(pos($0) - a) < abs(pos($1) - a) } ?? 0
        dragging = nearest; selected = nearest
        move(nearest, to: a)
    }

    override func mouseDragged(with e: NSEvent) {
        if let i = dragging { move(i, to: along(e)) }
    }

    override func mouseUp(with e: NSEvent) { dragging = nil }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 126, 123: move(selected, to: pos(selected) - 1)   // up / left
        case 125, 124: move(selected, to: pos(selected) + 1)   // down / right
        case 48: selected = (selected + 1) % fractions.count; needsDisplay = true
        case 53: onDone?()
        default: super.keyDown(with: e)
        }
    }

    private func move(_ i: Int, to a: CGFloat) {
        let v = Double(min(max(a, 0), length - 1) / length)
        // keep the two notches apart so the mapping stays well defined
        let other = fractions[1 - i]
        guard abs(v - other) > 0.02 else { return }
        fractions[i] = v
        needsDisplay = true
        onDrag?(i, v)
    }
}
