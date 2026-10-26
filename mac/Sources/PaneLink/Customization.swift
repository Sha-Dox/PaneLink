import Carbon.HIToolbox
import Foundation

/// A user-chosen global shortcut (Carbon key code + Carbon modifier mask).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var mods: UInt32        // cmdKey | shiftKey | optionKey | controlKey
    var key: String         // label for the key, captured when it was recorded

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    static func hyper(_ code: Int, _ key: String) -> Shortcut {
        Shortcut(keyCode: UInt32(code), mods: UInt32(controlKey | optionKey | cmdKey), key: key)
    }
}

enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case extend, lowPower, stats, align, wake, rest
    var id: String { rawValue }
    var label: String {
        switch self {
        case .extend: "Extend displays on/off"
        case .lowPower: "Low power on/off"
        case .stats: "Stats overlay on/off"
        case .align: "Align cursor (next edge)"
        case .wake: "Wake the Windows PC"
        case .rest: "Rest the Windows PC (pause its apps)"
        }
    }
    var defaultShortcut: Shortcut? {
        switch self {
        case .extend: .hyper(kVK_ANSI_E, "E")
        case .lowPower: .hyper(kVK_ANSI_L, "L")
        case .stats: .hyper(kVK_ANSI_S, "S")
        case .align: .hyper(kVK_ANSI_A, "A")
        case .wake, .rest: nil
        }
    }
}

struct OverlayPrefs: Codable, Equatable {
    enum Corner: String, Codable, CaseIterable, Identifiable {
        case topRight = "Top right", topLeft = "Top left", bottomRight = "Bottom right", bottomLeft = "Bottom left"
        var id: String { rawValue }
    }
    enum Field: String, Codable, CaseIterable, Identifiable {
        case fps = "Frame rate", total = "Total delay", encode = "Encode", network = "Network", windows = "Windows side",
             lost = "Lost frames", bitrate = "Bitrate"
        var id: String { rawValue }
    }
    var corner: Corner = .topRight
    var fields: [Field] = Field.allCases
    var fontSize: Double = 11.5
    var opacity: Double = 0.6
    var warnLost = 10           // turn orange above this many lost frames (10 s window)

    init() {}
    private enum K: String, CodingKey { case corner, fields, fontSize, opacity, warnLost }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        corner = (try? c.decode(Corner.self, forKey: .corner)) ?? corner
        fields = (try? c.decode([Field].self, forKey: .fields)) ?? fields
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? fontSize
        opacity = (try? c.decode(Double.self, forKey: .opacity)) ?? opacity
        warnLost = (try? c.decode(Int.self, forKey: .warnLost)) ?? warnLost
    }
}

/// Which extras the menu bar dropdown shows.
struct MenuPrefs: Codable, Equatable {
    var lowPower = true
    var statsOverlay = true
    var wake = true
    var rest = true
    var monitors = true
    var testPattern = true

    init() {}
    private enum K: String, CodingKey { case lowPower, statsOverlay, wake, rest, monitors, testPattern }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        lowPower = (try? c.decode(Bool.self, forKey: .lowPower)) ?? lowPower
        statsOverlay = (try? c.decode(Bool.self, forKey: .statsOverlay)) ?? statsOverlay
        wake = (try? c.decode(Bool.self, forKey: .wake)) ?? wake
        rest = (try? c.decode(Bool.self, forKey: .rest)) ?? rest
        monitors = (try? c.decode(Bool.self, forKey: .monitors)) ?? monitors
        testPattern = (try? c.decode(Bool.self, forKey: .testPattern)) ?? testPattern
    }
}

/// Everything newer that only tunes behaviour, kept together so Settings stays readable.
struct Tuning: Codable, Equatable {
    var shortcuts: [HotkeyAction: Shortcut] = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.compactMap { a in a.defaultShortcut.map { (a, $0) } })
    var overlay = OverlayPrefs()
    var menu = MenuPrefs()
    var lowPowerFps = 60                 // 30 / 40 / 60 (divisors of 120, so no judder on Windows)
    var autoStopMousePx = 40             // mouse travel that counts as "using the PC"; 0 = ignore the mouse
    var autoStopGraceSec = 2.0           // ignore input this long after extending starts
    var gpuCapMHz = 1100                 // GPU core clock cap in low-power GPU mode
    var stallMs = 120                    // link considered dead after this much viewer silence
    var colorPresets: [String: ColorSettings] = [:]

    init() {}
    private enum K: String, CodingKey { case shortcuts, overlay, menu, lowPowerFps, autoStopMousePx, autoStopGraceSec, gpuCapMHz, stallMs, colorPresets }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        if let raw = try? c.decode([String: Shortcut].self, forKey: .shortcuts) {
            shortcuts = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in HotkeyAction(rawValue: k).map { ($0, v) } })
        }
        overlay = (try? c.decode(OverlayPrefs.self, forKey: .overlay)) ?? overlay
        menu = (try? c.decode(MenuPrefs.self, forKey: .menu)) ?? menu
        lowPowerFps = (try? c.decode(Int.self, forKey: .lowPowerFps)) ?? lowPowerFps
        autoStopMousePx = (try? c.decode(Int.self, forKey: .autoStopMousePx)) ?? autoStopMousePx
        autoStopGraceSec = (try? c.decode(Double.self, forKey: .autoStopGraceSec)) ?? autoStopGraceSec
        gpuCapMHz = (try? c.decode(Int.self, forKey: .gpuCapMHz)) ?? gpuCapMHz
        stallMs = (try? c.decode(Int.self, forKey: .stallMs)) ?? stallMs
        colorPresets = (try? c.decode([String: ColorSettings].self, forKey: .colorPresets)) ?? colorPresets
    }
    func encode(to e: Swift.Encoder) throws {
        var c = e.container(keyedBy: K.self)
        try c.encode(Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) }), forKey: .shortcuts)
        try c.encode(overlay, forKey: .overlay); try c.encode(menu, forKey: .menu)
        try c.encode(lowPowerFps, forKey: .lowPowerFps); try c.encode(autoStopMousePx, forKey: .autoStopMousePx)
        try c.encode(autoStopGraceSec, forKey: .autoStopGraceSec); try c.encode(gpuCapMHz, forKey: .gpuCapMHz)
        try c.encode(stallMs, forKey: .stallMs); try c.encode(colorPresets, forKey: .colorPresets)
    }
}
