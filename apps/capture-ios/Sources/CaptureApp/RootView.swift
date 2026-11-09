#if os(iOS)
import CaptureKit
import SwiftUI

public struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var pairingText = ""

    public init() {}

    public var body: some View {
        content
            .environmentObject(model)
            .onOpenURL { model.receive(url: $0) }
            .alert(
                model.pairedHost == nil ? "Pair with this server?" : "Replace your current server?",
                isPresented: Binding(get: { model.pendingLink != nil }, set: { if !$0 { model.rejectPending() } })
            ) {
                Button("Pair") { model.confirmPending() }
                Button("Cancel", role: .cancel) { model.rejectPending() }
            } message: {
                Text("Your photos will be uploaded to \(model.pendingLink?.server.host ?? "?"). "
                    + "Only continue if you started this from your own server.")
            }
            .sheet(isPresented: $model.showNearbyMac) { NearbyMacView().environmentObject(model) }
            .padding()
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .needsPairing:
            VStack(spacing: 12) {
                Text("Pair with your server").font(.title2)
                Text("Open the pairing link from the web app on this phone, or paste it here.")
                    .multilineTextAlignment(.center)
                TextField("scan3d://pair?server=...&token=...", text: $pairingText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Pair") {
                    if let url = URL(string: pairingText) { model.receive(url: url) }
                }
                Divider().padding(.vertical, 8)
                Text("Or send scans straight to a Mac on this Wi-Fi network.")
                    .multilineTextAlignment(.center)
                Button("Find a Mac nearby") { model.showNearbyMac = true }.buttonStyle(.borderedProminent)
            }
        case .ready:
            VStack(spacing: 12) {
                if model.pendingCapture != nil {
                    Button("Resume saved capture") { model.recoverCapture() }.buttonStyle(.borderedProminent)
                }
                if let host = model.pairedHost { Text("Server: \(host)").font(.footnote) }
                if let mac = model.pairedMac { Text("Mac: \(mac.name)").font(.footnote) }
                if ObjectCaptureAvailability.isSupported {
                    Button("Scan an object") { model.beginCapture() }.buttonStyle(.borderedProminent)
                } else {
                    Text("This device has no LiDAR, so guided capture is unavailable.")
                        .multilineTextAlignment(.center)
                }
                Button(model.pairedMac == nil ? "Find a Mac nearby" : "Change Mac") { model.showNearbyMac = true }
                if model.pairedHost != nil { Button("Unpair server", role: .destructive) { model.unpair() } }
                if model.pairedMac != nil { Button("Forget Mac", role: .destructive) { model.forgetMac() } }
            }
        case .capturing:
            CaptureScreen()
        case .choosing(let folder):
            VStack(spacing: 12) {
                Text("Capture complete").font(.title2)
                Button(model.pairedMac == nil ? "Find a Mac nearby" : "Change Mac or pairing code") {
                    model.showNearbyMac = true
                }
                if model.pairedMac != nil {
                    Button("Send to \(model.pairedMac?.name ?? "my Mac")") {
                        Task { await model.sendToMac(folder: folder, name: "Scan") }
                    }.buttonStyle(.borderedProminent)
                    Text("Builds the model on this phone, then sends it over Wi-Fi.")
                        .font(.footnote).multilineTextAlignment(.center)
                }
                if model.pairedHost != nil {
                    Button("Send photos to my server (best detail)") {
                        Task { await model.submit(imagesDirectory: folder.appendingPathComponent("Images"), name: "Scan") }
                    }
                    Button("Reconstruct on this phone and upload") {
                        Task { await model.submitOnDevice(folder: folder, name: "Scan") }
                    }
                }
            }
        case .reconstructing:
            ProgressView("Reconstructing on this phone...")
        case .submitting(let done, let total):
            ProgressView("Uploading \(done) of \(total)", value: Double(done), total: Double(max(total, 1)))
        case .sendingToMac(let name):
            ProgressView("Sending to \(name)...")
        case .sentToMac(let name):
            VStack(spacing: 8) {
                Text("Sent to \(name)").font(.title2)
                Text("It opens in Scanbench on your Mac.")
                Button("Scan another") { model.cancelCapture() }
            }
        case .submitted(let jobId, let photos):
            VStack(spacing: 8) {
                Text("Uploaded \(photos) photos").font(.title2)
                Text("Job \(jobId.prefix(8)) is queued for reconstruction on your Mac.")
                Button("Scan another") { model.cancelCapture() }
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message).multilineTextAlignment(.center)
                Button("Back") { model.recoverCapture() }
            }
        }
    }
}
#endif
