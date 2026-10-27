import AppKit
import SwiftUI

@main
struct PaneLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: state)
        } label: {
            MenuBarIcon(on: state.isOn).modifier(FirstRunOpener(state: state))
        }
        .menuBarExtraStyle(.window)

        Window("PaneLink", id: "main") {
            MainWindow(state: state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--aligntest") { AlignSelfTest.run(); return }
        if CommandLine.arguments.contains("--windowtest") { AlignSelfTest.windowTest(); return }
        if CommandLine.arguments.contains("--dummywindow") { AlignSelfTest.dummyWindow(); return }
        if CommandLine.arguments.contains("--overlaytest") { AlignSelfTest.overlayTest(); return }
        if CommandLine.arguments.contains("--hotkeytest") {
            // register, then post ⌃⌥⌘S at the HID level and check the action ran
            Hotkeys.setEnabled(true)
            let before = AppState.shared.settings.statsOverlay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let src = CGEventSource(stateID: .hidSystemState)   // default ⌃⌥⌘S
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: src, virtualKey: 0x01, keyDown: down)!
                    e.flags = [.maskControl, .maskAlternate, .maskCommand]
                    e.post(tap: .cghidEventTap)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let after = AppState.shared.settings.statsOverlay
                    FileHandle.standardError.write("hotkey toggled stats overlay: \(before) -> \(after)\n".data(using: .utf8)!)
                    AppState.shared.settings.statsOverlay = before
                    exit(after != before ? 0 : 1)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--pipetest") { AlignSelfTest.pipeTest(); return }
        if CommandLine.arguments.contains("--hidpitest") { AlignSelfTest.hiDPITest(); return }
        if CommandLine.arguments.contains("--uishot") { AlignSelfTest.uiShot(); return }
        if CommandLine.arguments.contains("--stalltest") { AlignSelfTest.stallTest(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--pairtest"), i + 2 < CommandLine.arguments.count {
            // --pairtest <host> <code>: the setup card's flow without the UI (dev builds only touch the dev settings)
            let st = AppState.shared, host = CommandLine.arguments[i + 1], code = CommandLine.arguments[i + 2]
            st.pair(with: host)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print("after PAIR: \(st.pairing)")
                st.submit(code: code)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    print("after code: pairing=\(st.pairing) token=\(st.settings.token.isEmpty ? "none" : "set") mac=\(st.settings.wakeMAC) name=\(st.settings.pcName) monitors=\(st.monitors.count)")
                    exit(st.settings.token.isEmpty ? 1 : 0)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--discoverytest") {
            Task {
                let pcs = await Discovery.scan()
                for pc in pcs { print("\(pc.name) \(pc.host):\(pc.port) \(pc.mac)") }
                exit(pcs.isEmpty ? 1 : 0)
            }
            return
        }
        if CommandLine.arguments.contains("--waketest") {
            let st = AppState.shared.settings
            let ok = WakeOnLAN.send(mac: st.wakeMAC, hosts: st.hosts)
            FileHandle.standardError.write("wake sent: \(ok)\n".data(using: .utf8)!); exit(ok ? 0 : 1)
        }
        _ = AppState.shared
        CursorAligner.shared.settingsProvider = {
            // read off the main actor only through this snapshot (called from main in rebuild)
            MainActor.assumeIsolated { (AppState.shared.settings.cursorAlign, AppState.shared.settings.edgeNotches) }
        }
        CursorAligner.shared.activate()
        // `kill`/logout: still tear down cleanly so Wi-Fi tuning and Windows refresh rates are restored.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { MainActor.assumeIsolated { AppState.shared.stop() }; exit(0) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { AppState.shared.stop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Template image from the bundle (outline when off, filled while extending); SF Symbol fallback for dev builds.
struct MenuBarIcon: View {
    let on: Bool
    private static let images: [Bool: NSImage] = {
        var out: [Bool: NSImage] = [:]
        for (k, name) in [(true, "MenuIconOn"), (false, "MenuIconOff")] {
            if let img = Bundle.main.image(forResource: name) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                out[k] = img
            }
        }
        return out
    }()

    var body: some View {
        if let img = Self.images[on] { Image(nsImage: img) }
        else { Image(systemName: on ? "display.2" : "display") }
    }
}

/// A menu bar app shows nothing at launch: on the first run (no PC yet) open the setup window.
/// Lives on the menu bar icon because that's the one view SwiftUI renders right away.
struct FirstRunOpener: ViewModifier {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear {
            guard state.isFirstRun, !CommandLine.arguments.contains(where: { $0.hasPrefix("--") && $0 != "--autostart" }) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
