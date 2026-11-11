#if os(iOS)
import CaptureKit
import SwiftUI

/// Connections and storage. Kept out of the scan flow: pairing happens once, scanning every time.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForgetMac = false
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    if let mac = model.pairedMac {
                        LabeledContent("Paired with", value: mac.name)
                        Button("Change Mac or code") { dismiss(); model.showNearbyMac = true }
                        Button("Forget this Mac", role: .destructive) { confirmForgetMac = true }
                    } else {
                        Button("Find a Mac nearby") { dismiss(); model.showNearbyMac = true }
                    }
                }
                if let host = model.pairedHost {
                    Section("Server") {
                        LabeledContent("Server", value: host)
                        Button("Unpair server", role: .destructive) { confirmUnpair = true }
                    }
                }
                Section {
                    LabeledContent("Used by scans", value: ByteCountFormatter.string(fromByteCount: model.catalog.totalStorageBytes(), countStyle: .file))
                    if !model.unfinishedScans.isEmpty {
                        Button("Discard \(model.unfinishedScans.count) unfinished scan(s)", role: .destructive) {
                            model.discardUnfinishedScans()
                        }
                    }
                } header: { Text("Storage") } footer: {
                    Text("Scans you sent are removed from this phone after a week. Scans you have not sent are never removed automatically.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Forget this Mac?", isPresented: $confirmForgetMac, titleVisibility: .visible) {
                Button("Forget Mac", role: .destructive) { model.forgetMac() }
            }
            .confirmationDialog("Unpair the server?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { model.unpair() }
            }
        }
    }
}
#endif
