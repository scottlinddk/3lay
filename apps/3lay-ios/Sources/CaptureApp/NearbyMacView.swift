#if os(iOS)
import CaptureKit
import ScanLink
import SwiftUI

/// Finds 3lay Mac on the local network and pairs with it using the code shown on the Mac.
@MainActor
final class NearbyBrowserModel: ObservableObject {
    @Published var macs: [DiscoveredMac] = []
    @Published var problem: String?
    private let browser = MacBrowser()

    func start() {
        browser.onResults = { [weak self] in self?.macs = $0 }
        browser.onProblem = { [weak self] in self?.problem = $0 }
        browser.start()
    }

    func stop() { browser.stop() }
}

struct NearbyMacView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var browser = NearbyBrowserModel()
    @State private var selected: DiscoveredMac?
    @State private var manualAddress = ""
    @State private var showManual = false
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Macs running 3lay Mac") {
                    if browser.macs.isEmpty {
                        HStack { ProgressView(); Text("Searching this Wi-Fi network...") }
                    }
                    ForEach(browser.macs) { mac in
                        Button {
                            selected = mac
                            showManual = false
                        } label: {
                            HStack {
                                Text(mac.name)
                                Spacer()
                                if selected == mac { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if let problem = browser.problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
                    Button("My Mac is not listed") { showManual = true; selected = nil }
                }
                if showManual {
                    Section("Mac address") {
                        TextField("192.168.1.20 or my-mac.local", text: $manualAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL)
                        Text("Shown in 3lay Mac under Import a scan. Local network addresses only.")
                            .font(.footnote)
                    }
                }
                if selected != nil || showManual {
                    Section("Pairing code") {
                        TextField("6 digits shown on the Mac", text: $code)
                            .keyboardType(.numberPad)
                            .onChange(of: code) { _, new in code = String(new.filter(\.isNumber).prefix(LanProtocol.codeLength)) }
                        Button(busy ? "Checking..." : "Pair") { Task { await pair() } }
                            .disabled(busy || !LanProtocol.isValidCode(code))
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Nearby Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.showNearbyMac = false } } }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func pair() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let endpoint: LanEndpoint
            if showManual {
                guard let parsed = LanEndpoint.parse(manualAddress) else {
                    error = "Enter an address on your local network, such as 192.168.1.20."
                    return
                }
                endpoint = parsed
            } else if let selected {
                endpoint = try await MacBrowser.resolve(selected)
            } else { return }
            try await model.pairMac(endpoint: endpoint, code: code)
        } catch { self.error = error.localizedDescription }
    }
}
#endif
