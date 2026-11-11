#if os(iOS)
import CaptureKit
import SwiftUI

/// Chooses the kind of scan, in plain words. The two modes are different workflows with different results.
struct NewScanSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    option(
                        title: "Object", symbol: "cube",
                        detail: "Walk around something you can hold or place on a table. Guided photos give the sharpest detail.",
                        available: ObjectCaptureAvailability.isSupported,
                        unavailable: "Needs an iPhone or iPad with LiDAR."
                    ) { model.beginCapture() }
                    option(
                        title: "Room or large object", symbol: "viewfinder",
                        detail: "Records the surroundings with LiDAR and photos. Best for rooms, furniture and big things.",
                        available: LidarCapture.isSupported,
                        unavailable: "Needs an iPhone or iPad with LiDAR."
                    ) { model.beginLidarCapture() }
                } footer: {
                    Text("Both send to your Mac, where the finished model is built.")
                }
            }
            .navigationTitle("New Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }

    private func option(
        title: String, symbol: String, detail: String, available: Bool, unavailable: String, action: @escaping () -> Void
    ) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.title2).frame(width: 32).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(available ? detail : unavailable).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .disabled(!available)
        .accessibilityElement(children: .combine)
    }
}
#endif
