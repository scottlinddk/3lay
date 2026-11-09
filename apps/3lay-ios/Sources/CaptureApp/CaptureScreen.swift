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
    @State private var confirmEarlyFinish = false
    @State private var failureMessage: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            ObjectCaptureView(session: session)
            VStack(spacing: 12) {
                Text(guidance).font(.subheadline).multilineTextAlignment(.center)
                if session.state == .capturing {
                    Text("Photos: \(session.numberOfShotsTaken) of \(Submission.minimumPhotos)+ recommended")
                        .font(.headline)
                }
                controls
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
        .onAppear(perform: start)
        .onChange(of: session.state) { _, state in
            // The object box still needs framing, but the first tap on "Detect" adds nothing.
            if state == .ready { Task { await beginDetecting() } }
            if state == .completed { finished = true }
            if case .failed(let error) = state { failureMessage = error.localizedDescription }
        }
        .confirmationDialog(
            "Only \(session.numberOfShotsTaken) photos. \(Submission.minimumPhotos) or more give a much better model.",
            isPresented: $confirmEarlyFinish, titleVisibility: .visible
        ) {
            Button("Finish anyway", role: .destructive) { session.finish() }
            Button("Keep scanning", role: .cancel) {}
        }
        .onChange(of: finished) { _, done in
            if done { model.captureFinished(folder: folder) }
        }
    }

    @ViewBuilder private var controls: some View {
        switch session.state {
        case .detecting:
            Button("Start capture") { session.startCapturing() }.buttonStyle(.borderedProminent)
        case .capturing:
            if session.userCompletedScanPass {
                // One lap is rarely enough for detail. Another lap from a new height, or with the
                // object flipped, fills in the sides and underside.
                Button("Another lap, higher or lower") { session.beginNewScanPass() }.buttonStyle(.bordered)
                Button("Flip the object and scan again") { session.beginNewScanPassAfterFlip() }.buttonStyle(.bordered)
            }
            Button("Finish") {
                if session.numberOfShotsTaken < Submission.minimumPhotos { confirmEarlyFinish = true }
                else { session.finish() }
            }.buttonStyle(.borderedProminent)
        case .ready:
            // Manual fallback if the automatic attempt below never succeeds.
            Button("Continue") { _ = session.startDetecting() }.buttonStyle(.borderedProminent)
        case .failed:
            EmptyView()
        default:
            ProgressView()
        }
        Button(failureMessage == nil ? "Cancel" : "Back", role: .cancel) { session.cancel(); model.cancelCapture() }
    }

    /// One plain sentence for what the user should do now. ARKit reports what is wrong
    /// (too close, too fast, too dark) and we say it, instead of leaving them to guess.
    private var guidance: String {
        switch session.state {
        case .detecting: return "Point at the object. Tap Start when the box surrounds it."
        case .capturing:
            let feedback = session.feedback
            if feedback.contains(.movingTooFast) { return "Move slower." }
            if feedback.contains(.objectTooClose) { return "Move back a little." }
            if feedback.contains(.objectTooFar) { return "Move closer." }
            if feedback.contains(.environmentLowLight) || feedback.contains(.environmentTooDark) {
                return "Too dark. Add light."
            }
            if feedback.contains(.outOfFieldOfView) { return "Keep the object in view." }
            if session.userCompletedScanPass { return "Lap done. Scan another lap at a different height for more detail, or finish." }
            return "Walk slowly around the object. Keep it in view."
        case .failed:
            // Without this a failed session sat on "Getting ready..." forever.
            return "Scanning could not start: \(failureMessage ?? "unknown error")"
        default: return "Getting ready..."
        }
    }

    /// `state` turns `.ready` slightly before the session accepts `startDetecting()` (the log says
    /// "called in wrong state=running"). A single call is silently rejected and the screen stays on
    /// "Getting ready..." forever, so retry briefly until it is accepted.
    private func beginDetecting() async {
        for _ in 0..<20 {
            guard session.state == .ready else { return }
            if session.startDetecting() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func start() {
        // onAppear can fire again; a second start() on a running session fails.
        guard session.state == .initializing else { return }
        let images = folder.appendingPathComponent("Images")
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var config = ObjectCaptureSession.Configuration()
        // Keeps extra photos beyond what the phone's live guidance asks for. The Mac uses them all,
        // which is what makes a sharper model than a single lap around the object.
        config.isOverCaptureEnabled = true
        config.checkpointDirectory = folder.appendingPathComponent("Checkpoint")
        session.start(imagesDirectory: images, configuration: config)
    }

    private static func newFolder() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("captures/\(UUID().uuidString)")
    }
}
#endif
