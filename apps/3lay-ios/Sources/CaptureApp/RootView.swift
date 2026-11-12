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
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        // The camera screens use the whole display. Everything else sits in the safe area.
        case .capturing:
            CaptureScreen()
        case .lidarCapturing:
            if let folder = model.activeLidarFolder { LidarCaptureScreen(folder: folder) }
        case .ready:
            HomeView()
        case .needsPairing:
            ScrollView { welcome.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity) }
                .scrollDismissesKeyboard(.interactively)
        case .lidarReady:
            if let pending = model.pendingLidar, let record = model.catalog.record(id: pending.id) {
                ReviewView(record: record, folder: pending.folder).id(record.id)
            } else {
                Color.clear.onAppear { model.recoverCapture() }
            }
        case .choosing(let folder):
            ReviewView(record: model.objectRecord(for: folder), folder: folder).id(folder)
        case .working:
            OperationView().padding()
        case .viewing(let folder, let url):
            VStack(spacing: 8) {
                ModelPreview(url: url)
                if let mac = model.pairedMac {
                    Button("Send to \(mac.name)") { model.sendToMac(folder: folder, name: model.objectRecord(for: folder).name) }
                        .buttonStyle(.borderedProminent)
                }
                Text("This is the reduced-detail phone build. The Mac builds a sharper one from the photos.")
                    .font(.footnote).multilineTextAlignment(.center)
                Button("Done") { model.recoverCapture() }
            }
            .padding()
        case .sentToMac(let name):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
                Text("Sent to \(name)").font(.title2)
                Text("3lay Mac has the scan. Open it there to build and inspect the model.")
                    .multilineTextAlignment(.center)
                Button("Done") { model.cancelCapture() }.buttonStyle(.borderedProminent)
            }
            .padding()
        case .submitted(let jobId, let photos):
            VStack(spacing: 12) {
                Text(photos > 0 ? "Uploaded \(photos) photos" : "Uploaded").font(.title2)
                Text("Job \(jobId.prefix(8)) is queued for reconstruction on your server.")
                Button("Done") { model.cancelCapture() }.buttonStyle(.borderedProminent)
            }
            .padding()
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center)
                Button("Back") { model.recoverCapture() }.buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    /// First launch: a Mac on the same Wi-Fi is the main path; a server is the alternative.
    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.transparent").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Welcome to 3lay").font(.largeTitle.bold())
            Text("Scan with this phone, finish on your Mac. Open 3lay Mac on the same Wi-Fi network, then pair.")
                .multilineTextAlignment(.center)
            Button { model.showNearbyMac = true } label: {
                Label("Find a Mac nearby", systemImage: "desktopcomputer").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            DisclosureGroup("Use a server instead") {
                VStack(spacing: 8) {
                    Text("Open the pairing link from the web app on this phone, or paste it here.").font(.footnote)
                    TextField("scan3d://pair?server=...&token=...", text: $pairingText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .accessibilityLabel("Server pairing link")
                    Button("Pair") { if let url = URL(string: pairingText) { model.receive(url: url) } }
                }
                .padding(.top, 8)
            }
        }
    }
}
#endif
