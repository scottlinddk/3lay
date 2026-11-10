#if os(iOS)
import CaptureKit
import SwiftUI

/// Capture mode for rooms and large objects: LiDAR mesh plus photos. Small objects use `CaptureScreen`.
struct LidarCaptureScreen: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var capture = LidarCapture(folder: LidarCaptureScreen.newFolder())
    @State private var failure: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            LidarPreview(capture: capture).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(failure ?? capture.warning ?? "Walk slowly around the scene. The coloured mesh shows what LiDAR has seen. Photos are taken as you move.")
                    .font(.subheadline).multilineTextAlignment(.center)
                Text("Photos: \(capture.photoCount) · Mesh: \(capture.triangleCount / 1000)k triangles").font(.headline)
                Button("Finish") { finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(capture.triangleCount == 0 || capture.photoCount == 0)
                Button("Cancel", role: .cancel) { capture.cancel(); model.cancelCapture() }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }

    private func finish() {
        do {
            let result = try capture.finish(device: AppModel.device)
            model.lidarCaptureFinished(folder: result.folder, photos: result.photos, triangles: result.triangles)
        } catch {
            failure = "Could not save the scan: \(error.localizedDescription)"
        }
    }

    private static func newFolder() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lidar-captures/\(UUID().uuidString)")
    }
}
#endif
