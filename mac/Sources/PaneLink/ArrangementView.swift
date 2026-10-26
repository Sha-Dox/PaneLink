import AppKit
import SwiftUI

struct DisplayBox: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var frame: CGRect      // global CG coordinates (origin top-left of main display, y down)
    let name: String
    let isMain: Bool
    let isWindows: Bool
}

/// Drag-to-arrange editor for every active display, applied with CGConfigureDisplayOrigin
/// (exactly what System Settings › Displays does), with edge snapping so displays always touch.
struct ArrangementView: View {
    @ObservedObject var state: AppState
    @State private var boxes: [DisplayBox] = []
    @State private var dragging: CGDirectDisplayID?
    @State private var dragOffset: CGSize = .zero

    private let publisher = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(boxes: boxes, size: geo.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04))
                ForEach(boxes) { box in
                    let r = layout.rect(box.frame)
                    let moving = dragging == box.id
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(box.isWindows ? Color.accentColor.opacity(moving ? 0.55 : 0.35) : Color.gray.opacity(0.35))
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(box.isWindows ? Color.accentColor : Color.gray, lineWidth: moving ? 2 : 1)
                        VStack(spacing: 2) {
                            if box.isMain { Image(systemName: "menubar.rectangle").font(.caption) }
                            Text(box.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Text("\(Int(box.frame.width))×\(Int(box.frame.height))").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(4)
                    }
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX + (moving ? dragOffset.width : 0), y: r.minY + (moving ? dragOffset.height : 0))
                    .gesture(box.isMain ? nil : DragGesture()
                        .onChanged { g in dragging = box.id; dragOffset = g.translation }
                        .onEnded { g in
                            let delta = CGSize(width: g.translation.width / layout.scale, height: g.translation.height / layout.scale)
                            commit(box, proposed: box.frame.offsetBy(dx: delta.width, dy: delta.height))
                            dragging = nil; dragOffset = .zero
                        })
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(publisher) { _ in reload() }
        .onChange(of: state.phase) { _, _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: reload) }
    }

    private func reload() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let virtuals = state.virtualDisplayIDs()
        let names = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return (id, s.localizedName)
        })
        boxes = ids.prefix(Int(n)).map { id in
            DisplayBox(id: id, frame: CGDisplayBounds(id), name: virtuals[id] ?? names[id] ?? "Display",
                       isMain: CGDisplayIsMain(id) != 0, isWindows: virtuals[id] != nil)
        }
    }

    private func commit(_ box: DisplayBox, proposed: CGRect) {
        let others = boxes.filter { $0.id != box.id }.map(\.frame)
        let target = Self.snap(proposed, to: others)
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        CGConfigureDisplayOrigin(cfg, box.id, Int32(target.minX.rounded()), Int32(target.minY.rounded()))
        CGCompleteDisplayConfiguration(cfg, .permanently)
        if let i = boxes.firstIndex(of: box) { boxes[i].frame = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: reload)
    }

    /// Nearest position where `r` shares an edge with some other display without overlapping any.
    static func snap(_ r: CGRect, to others: [CGRect]) -> CGRect {
        var best = r, bestDist = CGFloat.infinity
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
        for o in others {
            let y = clamp(r.minY, o.minY - r.height + 1, o.maxY - 1)
            let x = clamp(r.minX, o.minX - r.width + 1, o.maxX - 1)
            let candidates = [
                CGPoint(x: o.maxX, y: y), CGPoint(x: o.minX - r.width, y: y),
                CGPoint(x: x, y: o.maxY), CGPoint(x: x, y: o.minY - r.height),
            ]
            for c in candidates {
                var cr = CGRect(origin: c, size: r.size)
                // snap aligned edges when close (top/bottom/left/right flush)
                for a in [o.minY, o.maxY - r.height] where abs(cr.minY - a) < 60 && (c.x == o.maxX || c.x == o.minX - r.width) { cr.origin.y = a }
                for a in [o.minX, o.maxX - r.width] where abs(cr.minX - a) < 60 && (c.y == o.maxY || c.y == o.minY - r.height) { cr.origin.x = a }
                if others.contains(where: { $0.intersects(cr.insetBy(dx: 1, dy: 1)) }) { continue }
                let d = hypot(cr.minX - r.minX, cr.minY - r.minY)
                if d < bestDist { bestDist = d; best = cr }
            }
        }
        return best
    }

    struct Layout {
        let scale: CGFloat, origin: CGPoint, offset: CGPoint
        init(boxes: [DisplayBox], size: CGSize) {
            let all = boxes.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            guard !all.isNull else { scale = 1; origin = .zero; offset = .zero; return }
            let pad: CGFloat = 24
            scale = min((size.width - pad * 2) / all.width, (size.height - pad * 2) / all.height)
            origin = all.origin
            offset = CGPoint(x: (size.width - all.width * scale) / 2, y: (size.height - all.height * scale) / 2)
        }
        func rect(_ f: CGRect) -> CGRect {
            CGRect(x: (f.minX - origin.x) * scale + offset.x, y: (f.minY - origin.y) * scale + offset.y,
                   width: f.width * scale, height: f.height * scale)
        }
    }
}
