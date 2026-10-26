import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts, user-assignable (Settings › Controls). Carbon hot keys need no permission.
@MainActor
enum Hotkeys {
    private static var refs: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?
    private static var ids: [UInt32: HotkeyAction] = [:]

    static func perform(_ a: HotkeyAction) {
        let st = AppState.shared
        switch a {
        case .extend: st.toggle()
        case .lowPower: st.settings.lowPowerManual.toggle()
        case .stats: st.settings.statsOverlay.toggle()
        case .align: st.alignNextEdge()
        case .wake: st.wake(); st.reconnect()
        case .rest: st.setRest(!st.restActive)
        }
    }

    static func setEnabled(_ on: Bool) {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll(); ids.removeAll()
        guard on else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { MainActor.assumeIsolated { if let a = Hotkeys.ids[id] { Hotkeys.perform(a) } } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        for (i, a) in HotkeyAction.allCases.enumerated() {
            guard let sc = AppState.shared.settings.tuning.shortcuts[a] else { continue }
            var ref: EventHotKeyRef?
            let id = UInt32(i + 1)
            let st = RegisterEventHotKey(sc.keyCode, sc.mods, EventHotKeyID(signature: OSType(0x504E4C4B), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref { refs.append(ref); ids[id] = a } else { Log.write("hotkey \(sc.display) for \(a.label) unavailable (\(st))") }
        }
    }

    /// While recording a new shortcut, the old ones must not fire.
    static func suspend() { refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll(); ids.removeAll() }
    static func resume() { setEnabled(AppState.shared.settings.hotkeys) }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    static func keyLabel(_ e: NSEvent) -> String {
        switch Int(e.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        if let i = fkeys.firstIndex(of: Int(e.keyCode)) { return "F\(i + 1)" }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
