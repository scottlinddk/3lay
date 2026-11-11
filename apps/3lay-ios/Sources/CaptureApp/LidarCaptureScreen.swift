#if os(iOS)
import CaptureKit
import SwiftUI

/// Capture mode for rooms and large objects: LiDAR mesh plus photos. Small objects use `CaptureScreen`.
struct LidarCaptureScreen: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var capture: LidarCapture
    @State private var failure: String?

    /// `folder` comes from the catalog record the model created, so the scan is tracked from its first frame.
    init(folder: URL) { _capture = StateObject(wrappedValue: LidarCapture(folder: folder)) }

    private var isBusy: Bool { capture.state != .capturing }

    var body: some View {
        ZStack(alignment: .bottom) {
            LidarPreview(capture: capture).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(message).font(.subheadline).multilineTextAlignment(.center)
                Text("Photos: \(capture.photoCount) · Mesh: \(capture.triangleCount / 1000)k triangles").font(.headline)
                if capture.state == .finishing {
                    ProgressView("Saving scan...")
                } else {
                    Button("Finish") { Task { await finish() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || capture.triangleCount == 0 || capture.photoCount == 0)
                }
                Button("Cancel", role: .cancel) { Task { await cancel() } }.disabled(capture.state == .cancelling)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }

    private var message: String {
        if let failure { return failure }
        switch capture.state {
        case .finishing: return "Saving the scan. This can take a moment for large scenes."
        case .cancelling: return "Cancelling..."
        default:
            return capture.warning ?? "Walk slowly around the scene. The coloured mesh shows what LiDAR has seen. Photos are taken as you move."
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
