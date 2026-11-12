#if os(iOS)
import CaptureKit
import SwiftUI

/// After capture: name the scan, see what was captured, and send it. One obvious action; the other ways
/// to finish (building on the phone, a server) are under "More options".
struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    let record: ScanRecord
    let folder: URL

    @State private var name: String
    @State private var photos = 0
    @State private var quality: ScanQualitySnapshot?
    @State private var confirmDiscard = false

    init(record: ScanRecord, folder: URL) {
        self.record = record
        self.folder = folder
        _name = State(initialValue: record.name.isEmpty ? (record.kind == .lidar ? "LiDAR scan" : "Scan") : record.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        ScanThumbnailView(folder: folder, kind: record.kind, size: 140)
                            .accessibilityHidden(true)
                        Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                if let quality { ScanQualitySection(snapshot: quality, folder: folder) }
                Section("Scan name") {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                        .accessibilityLabel("Scan name")
                }
                Section {
                    Label(destination, systemImage: "desktopcomputer")
                    if record.kind == .object || model.pairedMac != nil {
                        Menu("More options") {
                            if model.pairedMac != nil {
                                Button("Change Mac or code", systemImage: "desktopcomputer") { model.showNearbyMac = true }
                            }
                            if record.kind == .object {
                                if model.pairedMac != nil {
                                    Button("Build on this phone, then send", systemImage: "iphone") {
                                        commitName(); model.sendToMac(folder: folder, name: name)
                                    }
                                }
                                Button("Preview on this phone", systemImage: "cube") {
                                    commitName(); model.buildAndPreview(folder: folder)
                                }
                                if model.pairedHost != nil {
                                    Button("Send photos to my server", systemImage: "icloud.and.arrow.up") {
                                        commitName(); model.submit(imagesDirectory: folder.appendingPathComponent("Images"), name: name)
                                    }
                                    Button("Build on this phone and upload", systemImage: "iphone.and.arrow.forward") {
                                        commitName(); model.submitOnDevice(folder: folder, name: name)
                                    }
                                }
                            }
                        }

                    }
                } header: {
                    Text("Destination")
                } footer: {
                    Text("Your scan stays on this phone until you send or delete it.")
                }
                Section {
                    Button("Discard scan", role: .destructive) { confirmDiscard = true }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Review Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commitName(); model.leaveCapture() }
                        .accessibilityHint("Saves this scan and returns to your scans")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let mac = model.pairedMac {
                        Button(action: send) {
                            Label("Send to \(mac.name)", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    } else {
                        Button { model.showNearbyMac = true } label: {
                            Label("Find a Mac nearby", systemImage: "desktopcomputer")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
        .task {
            photos = ScanThumbnail.photoCount(folder: folder, kind: record.kind)
            var snapshot = ScanQualityFiles.loadSnapshot(folder: folder)
                ?? ScanQualitySnapshot(mode: record.kind == .lidar ? .lidar : .object, photoCount: photos)
            snapshot.photoCount = photos
            // Historical thermal state must not be presented as a current instruction.
            snapshot.thermal = Diagnostics.sample().thermal
            quality = snapshot
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard scan", role: .destructive) {
                if record.kind == .lidar { model.discardLidar() } else { model.discardCapture() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The scan on this phone is deleted and cannot be recovered.")
        }
    }

    private var summary: String {
        var parts = ["\(photos) photos"]
        if record.kind == .lidar, record.triangleCount > 0 { parts.append("\(record.triangleCount / 1000)k triangles") }
        parts.append(ByteCountFormatter.string(fromByteCount: model.catalog.storageBytes(of: record), countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private var destination: String {
        if let mac = model.pairedMac { return "Will be sent to \(mac.name)." }
        return "Pair with a Mac to send this scan. It stays on this phone until you do."
    }

    private func commitName() { model.rename(record.id, to: name) }

    private func send() {
        commitName()
        if record.kind == .lidar { model.sendLidarToMac(name: name) } else { model.sendPhotosToMac(folder: folder, name: name) }
    }
}
#endif
