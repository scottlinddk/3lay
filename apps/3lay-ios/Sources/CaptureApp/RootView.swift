#if os(iOS)
import CaptureKit
import SwiftUI

public struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var pairingText = ""
    @State private var confirmDiscard = false
    /// Also ask the Mac to rewrite the scan as a clean part with AI, and what the object is.
    @State private var cleanPart = false
    @State private var partNote = ""

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
                if LidarCapture.isSupported {
                    Button("Scan a room or large object (LiDAR)") { model.beginLidarCapture() }.buttonStyle(.borderedProminent)
                    Text("Records the LiDAR mesh with photos and sends it to your Mac. For small objects use Scan an object.")
                        .font(.footnote).multilineTextAlignment(.center)
                }
                Button(model.pairedMac == nil ? "Find a Mac nearby" : "Change Mac") { model.showNearbyMac = true }
                if model.pairedHost != nil { Button("Unpair server", role: .destructive) { model.unpair() } }
                if model.pairedMac != nil { Button("Forget Mac", role: .destructive) { model.forgetMac() } }
            }
        case .capturing:
            CaptureScreen()
        case .lidarCapturing:
            LidarCaptureScreen()
        case .lidarReady:
            VStack(spacing: 12) {
                Text("LiDAR scan saved").font(.title2)
                if let pending = model.pendingLidar {
                    Text("\(pending.photos) photos · \(pending.triangles / 1000)k triangles")
                }
                Button("Send to \(model.pairedMac?.name ?? "my Mac")") {
                    Task { await model.sendLidarToMac(name: "LiDAR scan") }
                }.buttonStyle(.borderedProminent)
                Button("Change Mac or pairing code") { model.showNearbyMac = true }
                Divider().padding(.vertical, 8)
                Button("Discard scan", role: .destructive) { confirmDiscard = true }
            }
            .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard scan", role: .destructive) { model.discardLidar() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The scan on this phone is deleted and cannot be recovered.")
            }
        case .choosing(let folder):
            VStack(spacing: 12) {
                Text("Capture complete").font(.title2)
                Button(model.pairedMac == nil ? "Find a Mac nearby" : "Change Mac or pairing code") {
                    model.showNearbyMac = true
                }
                if model.pairedMac != nil {
                    Toggle("Also rebuild as a clean part (AI)", isOn: $cleanPart)
                    if cleanPart {
                        TextField("What is it? For example: wall bracket with two holes", text: $partNote)
                            .textFieldStyle(.roundedBorder)
                        Text("Your Mac asks Claude to rewrite the scan as a clean part made of simple shapes, and keeps the scan too. "
                            + "Good for mechanical parts, not for figurines. Needs an Anthropic API key saved in 3lay Mac.")
                            .font(.footnote).multilineTextAlignment(.center)
                    }
                    Button("Send photos to \(model.pairedMac?.name ?? "my Mac")") {
                        Task { await model.sendPhotosToMac(folder: folder, name: "Scan", rebuild: cleanPart, note: partNote) }
                    }.buttonStyle(.borderedProminent)
                    Text("Fastest. The Mac builds the model, with more detail than the phone can.")
                        .font(.footnote).multilineTextAlignment(.center)
                    Button("Build on this phone, then send") {
                        Task { await model.sendToMac(folder: folder, name: "Scan", rebuild: cleanPart, note: partNote) }
                    }
                    Text("Slower and warms the phone. Works with any version of 3lay Mac.")
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
                Divider().padding(.vertical, 8)
                Button("Back (keep scan for later)") { model.leaveCapture() }
                Button("Discard scan", role: .destructive) { confirmDiscard = true }
            }
            .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard scan", role: .destructive) { model.discardCapture() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The photos on this phone are deleted and cannot be recovered.")
            }
        case .reconstructing(let fraction):
            if let fraction {
                ProgressView("Reconstructing on this phone... \(Int(fraction * 100))%", value: fraction)
            } else {
                ProgressView("Reconstructing on this phone...")
            }
        case .submitting(let done, let total):
            ProgressView("Uploading \(done) of \(total)", value: Double(done), total: Double(max(total, 1)))
        case .sendingToMac(let name):
            ProgressView("Packing and sending to \(name)...")
        case .sentToMac(let name):
            VStack(spacing: 8) {
                Text("Sent to \(name)").font(.title2)
                Text("It opens in 3lay Mac on your Mac.")
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
