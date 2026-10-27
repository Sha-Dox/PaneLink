import SwiftUI

/// Where the Windows installer is published.
let windowsDownloadURL = URL(string: "https://github.com/Sha-Dox/PaneLink/releases/latest")!

/// First run / re-pairing: find the PC on the network, ask it to show a code, type the code here.
struct SetupCard: View {
    @ObservedObject var state: AppState
    @State private var manual = ""
    @State private var code = ""

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                switch state.pairing {
                case .codeShown, .failed:
                    codeEntry
                case .needed where state.connectedHost != nil && !state.settings.hosts.isEmpty:
                    repair
                default:
                    if state.settings.hosts.isEmpty || state.pairing == .needed { picker } else { permissions }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: step == 3 ? "lock.shield" : "pc").font(.headline)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !state.screenAccess { state.refreshPermissions() }
        }
    }

    private var step: Int { state.settings.hosts.isEmpty || state.pairing != .none ? 2 : 3 }
    private var title: String { step == 3 ? "Step 3 of 3: allow screen recording" : "Set up your Windows PC" }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paired with \(state.settings.pcName.isEmpty ? "your PC" : state.settings.pcName). macOS needs your OK before PaneLink can stream the extra displays: turn on PaneLink under Screen & System Audio Recording.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Allow Screen Recording…") {
                    CGRequestScreenCaptureAccess()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .buttonStyle(.borderedProminent)
                Button("Relaunch PaneLink") { relaunch() }
                    .help("macOS sometimes only notices the permission after a restart")
            }
            Text("Optional: Accessibility permission (asked later) enables cursor alignment and putting windows back.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("1. On the PC, download PaneLink for Windows, unzip it and double-click Install.cmd.  2. Pick the PC here.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Link("Windows download", destination: windowsDownloadURL)
            }
            if state.discovered.isEmpty {
                HStack(spacing: 8) {
                    if state.scanning { ProgressView().controlSize(.small) }
                    Text(state.scanning ? "Looking on your network…" : "No PC found yet. Is PaneLink installed there, and is it on the same network as this Mac?")
                        .foregroundStyle(.secondary)
                }
            }
            if state.pairing == .needed && state.connectedHost == nil && !state.settings.hosts.isEmpty {
                Text("Can't reach \(state.settings.hosts[0]): \(state.connectionMessage)").font(.caption).foregroundStyle(.orange)
            }
            ForEach(state.discovered) { pc in
                HStack {
                    Image(systemName: "pc")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pc.name).font(.body.weight(.medium))
                        Text(pc.host).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Pair") { state.pair(with: pc.host, name: pc.name, mac: pc.mac) }
                        .buttonStyle(.borderedProminent)
                }
            }
            HStack {
                Button(state.scanning ? "Searching…" : "Search again") { state.scan() }.disabled(state.scanning)
                Spacer()
                TextField("or type its address", text: $manual).frame(width: 180)
                    .onSubmit { pairManual() }
                Button("Pair") { pairManual() }.disabled(manual.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { if state.discovered.isEmpty { state.scan() } }
    }

    private var repair: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(state.settings.pcName.isEmpty ? state.connectedHost ?? "The PC" : state.settings.pcName) doesn't know this Mac yet (or it was reset).")
                .foregroundStyle(.secondary)
            HStack {
                Button("Show pairing code on the PC") { state.showPairCode() }.buttonStyle(.borderedProminent)
                Button("Pick another PC") { state.forgetPC() }
            }
        }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A 6-digit code is now on the PC's screens (on the lock screen too). Type it here:")
                .foregroundStyle(.secondary)
            HStack {
                TextField("123 456", text: $code)
                    .font(.title2.monospacedDigit())
                    .frame(width: 140)
                    .onSubmit { state.submit(code: code) }
                    .onChange(of: code) { _, v in if v.filter(\.isNumber).count == 6 { state.submit(code: v) } }
                Button("Pair") { state.submit(code: code) }.buttonStyle(.borderedProminent)
                Button("New code") { code = ""; state.showPairCode() }
                Spacer()
                Button("Cancel") { code = ""; state.forgetPC() }
            }
            if case let .failed(why) = state.pairing { Text(why).foregroundStyle(.orange) }
        }
    }

    private func pairManual() {
        let h = manual.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty { state.pair(with: h) }
    }
}
