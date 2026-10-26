import SwiftUI

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
                default:
                    if state.settings.hosts.isEmpty || state.connectedHost == nil { picker } else { repair }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Set up your Windows PC", systemImage: "pc").font(.headline)
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install PaneLink on the PC (run Install.cmd from the Windows download), then pick it here.")
                .font(.callout).foregroundStyle(.secondary)
            if state.discovered.isEmpty {
                HStack(spacing: 8) {
                    if state.scanning { ProgressView().controlSize(.small) }
                    Text(state.scanning ? "Looking on your network…" : "No PC found yet. Same Wi-Fi/LAN as this Mac?")
                        .foregroundStyle(.secondary)
                }
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
