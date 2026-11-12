#if os(iOS)
import CaptureKit
import SwiftUI

/// Capture mode for rooms and large objects: LiDAR mesh plus photos. Small objects use `CaptureScreen`.
struct LidarCaptureScreen: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var capture: LidarCapture
    @State private var failure: String?
    @State private var confirmCancel = false

    /// `folder` comes from the catalog record the model created, so the scan is tracked from its first frame.
    init(folder: URL) { _capture = StateObject(wrappedValue: LidarCapture(folder: folder)) }

    private var isBusy: Bool { capture.state != .capturing }

    var body: some View {
        GeometryReader { geometry in
            LidarPreview(capture: capture).ignoresSafeArea()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ScrollView {
                        VStack(spacing: 12) {
                            Text(message).font(.subheadline).multilineTextAlignment(.center)
                            Text("Photos: \(capture.photoCount) · Mesh: \(capture.triangleCount / 1000)k triangles").font(.headline)
                            HStack(spacing: 12) {
                                Gauge(value: Double(capture.photoDetail), in: 0...100) { Text("Photo detail") } currentValueLabel: {
                                    Text("\(capture.photoDetail)%").monospacedDigit()
                                }
                                .gaugeStyle(.accessoryCircularCapacity)
                                .tint(capture.photoDetail >= 85 ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Label("needs photos", systemImage: "circle.fill").foregroundStyle(.red)
                                    Label("covered", systemImage: "circle.fill").foregroundStyle(.green)
                                    Text("Depth frames: \(capture.depthFrameCount)\(capture.highResCount > 0 ? " · full-resolution: \(capture.highResCount)" : "")")
                                        .foregroundStyle(.secondary)
                                    if capture.roomPlanActive { Text("Room layout: on").foregroundStyle(.secondary) }
                                }
                                .font(.caption)
                            }
                            if capture.coveragePlateau {
                                Text("Photo detail is not improving much. You can save and review what you have; you do not need to keep circling.")
                                    .font(.footnote).multilineTextAlignment(.center)
                            }
                            if capture.state == .finishing {
                                ProgressView("Saving scan...")
                            } else {
                                Button("Finish") { Task { await finish() } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(isBusy || capture.triangleCount == 0 || capture.photoCount == 0)
                            }
                            Button("Cancel", role: .cancel) {
                                if capture.photoCount > 0 { confirmCancel = true }
                                else { Task { await cancel() } }
                            }
                            .frame(minHeight: 44)
                            .disabled(isBusy)
                        }
                        .padding()
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .controlSize(.large)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: geometry.size.height * 0.48)
                    .background(.regularMaterial)
                }
        }
        .confirmationDialog("Discard this capture?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard capture", role: .destructive) { Task { await cancel() } }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("The photos and room data from this capture will be deleted.")
        }
    }

    private var message: String {
        if let failure { return failure }
        switch capture.state {
        case .finishing: return "Saving the scan. This can take a moment for large scenes."
        case .cancelling: return "Cancelling..."
        default:
            return capture.warning ?? "Walk slowly around the scene. Red mesh still needs photos, green is covered. Photos are taken as you move."
        }
    }

    private func finish() async {
        model.lidarCaptureSaving()
        do {
            let result = try await capture.finish(device: AppModel.device)
            model.lidarCaptureFinished(folder: result.folder, photos: result.photos, triangles: result.triangles)
        } catch is CancellationError {
            // Cancel is deleting the scan.
        } catch {
            // The photos are kept. The model marks the scan incomplete so it can be discarded, not sent.
            failure = "Could not save the scan: \(error.localizedDescription)"
            model.lidarCaptureFailed(error.localizedDescription)
        }
    }

    private func cancel() async {
        await capture.cancel()
        model.lidarCaptureCancelled()
    }
}
#endif
