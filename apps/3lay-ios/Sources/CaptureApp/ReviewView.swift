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
    @State private var confirmDiscard = false

    init(record: ScanRecord, folder: URL) {
        self.record = record
        self.folder = folder
        _name = State(initialValue: record.name.isEmpty ? (record.kind == .lidar ? "LiDAR scan" : "Scan") : record.name)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ScanThumbnailView(folder: folder, kind: record.kind, size: 140)
                    .padding(.top, 8)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .accessibilityLabel("Scan name")
                VStack(spacing: 4) {
                    Text(summary).font(.subheadline)
                    Text(destination).font(.footnote).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                if let mac = model.pairedMac {
                    Button { send() } label: {
                        Label("Send to \(mac.name)", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    if record.kind == .object {
                        Text("The Mac builds the model from your photos, with more detail than the phone can.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                } else {
                    Button { model.showNearbyMac = true } label: {
                        Label("Find a Mac nearby", systemImage: "desktopcomputer").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }

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

                Divider()
                Button("Save for later") { commitName(); model.leaveCapture() }
                Button("Discard scan", role: .destructive) { confirmDiscard = true }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Review")
        .task { photos = ScanThumbnail.photoCount(folder: folder, kind: record.kind) }
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
