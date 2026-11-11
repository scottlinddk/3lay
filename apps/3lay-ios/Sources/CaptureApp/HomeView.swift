#if os(iOS)
import CaptureKit
import SwiftUI

/// The first screen: your scans, and New Scan. Connection settings are one tap away, not on this screen.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showNewScan = false
    @State private var showSettings = false
    @State private var pendingDelete: ScanRecord?

    var body: some View {
        NavigationStack {
            List {
                if model.pairedMac == nil {
                    Section {
                        Button { model.showNearbyMac = true } label: {
                            Label("Pair with a Mac to send scans", systemImage: "desktopcomputer")
                        }
                    } footer: {
                        Text("Open 3lay Mac on your Mac, on the same Wi-Fi network.")
                    }
                }
                let scans = model.scans
                if scans.isEmpty {
                    ContentUnavailableView {
                        Label("No scans yet", systemImage: "cube.transparent")
                    } description: {
                        Text("Scan an object, or a room, and send it to your Mac.")
                    } actions: {
                        Button("New Scan") { showNewScan = true }.buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section("Scans") {
                        ForEach(scans) { scan in
                            Button { model.open(scan) } label: { ScanRow(scan: scan, folder: model.catalog.folderURL(scan)) }
                                .buttonStyle(.plain)
                                .disabled(!(scan.isRecoverable || scan.isDelivered))
                                .swipeActions {
                                    Button("Delete", role: .destructive) { pendingDelete = scan }
                                }
                        }
                    }
                }
            }
            .navigationTitle("3lay")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewScan = true } label: { Label("New Scan", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showNewScan) { NewScanSheet().environmentObject(model) }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
            .confirmationDialog(
                "Delete this scan?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { scan in
                Button("Delete scan", role: .destructive) { model.delete(scan) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The scan on this phone is deleted and cannot be recovered.")
            }
        }
    }
}

private struct ScanRow: View {
    let scan: ScanRecord
    let folder: URL

    var body: some View {
        HStack(spacing: 12) {
            ScanThumbnailView(folder: folder, kind: scan.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.name.isEmpty ? (scan.kind == .lidar ? "LiDAR scan" : "Scan") : scan.name).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(status.text).font(.footnote).foregroundStyle(status.color)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let kind = scan.kind == .lidar ? "Room / large object" : "Object"
        return "\(kind) · \(scan.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private var status: (text: String, color: Color) {
        switch scan.status {
        case .saved: return ("Ready to send", .blue)
        case .capturing, .saving: return ("Saving", .secondary)
        case .sending: return ("Interrupted", .orange)
        case .failed: return ("Not sent", .orange)
        case .sent: return ("Sent", .green)
        case .incomplete: return ("Incomplete", .red)
        }
    }
}
#endif
