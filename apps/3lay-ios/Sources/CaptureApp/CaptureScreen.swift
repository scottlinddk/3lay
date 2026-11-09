#if os(iOS)
import CaptureKit
import RealityKit
import SwiftUI

/// Guided Object Capture. Photos land in a per-capture folder that survives app restarts.
struct CaptureScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var session = ObjectCaptureSession()
    @State private var folder = CaptureScreen.newFolder()
    @State private var finished = false

    var body: some View {
        ZStack(alignment: .bottom) {
            ObjectCaptureView(session: session)
            VStack(spacing: 12) {
                Text("Photos: \(session.numberOfShotsTaken)").font(.headline)
                controls
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .onAppear(perform: start)
        .onChange(of: session.state) { _, state in
            if state == .completed { finished = true }
        }
        .onChange(of: finished) { _, done in
            if done { model.captureFinished(folder: folder) }
        }
    }

    @ViewBuilder private var controls: some View {
        switch session.state {
        case .ready:
            Button("Detect object") { _ = session.startDetecting() }.buttonStyle(.borderedProminent)
        case .detecting:
            Button("Start capture") { session.startCapturing() }.buttonStyle(.borderedProminent)
        case .capturing:
            Button("Finish") { session.finish() }
                .buttonStyle(.borderedProminent)
                .disabled(session.numberOfShotsTaken < Submission.minimumPhotos)
        default:
            ProgressView()
        }
        Button("Cancel", role: .cancel) { session.cancel(); model.cancelCapture() }
    }

    private func start() {
        let images = folder.appendingPathComponent("Images")
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = folder.appendingPathComponent("Checkpoint")
        session.start(imagesDirectory: images, configuration: config)
    }

    private static func newFolder() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("captures/\(UUID().uuidString)")
    }
}
#endif
