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
    @State private var confirmCancel = false
    @State private var failureMessage: String?
    @State private var completedPasses = 0
    @State private var observedQualityFeedback = Set<String>()

    var body: some View {
        GeometryReader { geometry in
            ObjectCaptureView(session: session)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ScrollView {
                        VStack(spacing: 12) {
                            Text(guidance).font(.subheadline).multilineTextAlignment(.center)
                            if session.state == .capturing {
                                Text("Photos: \(session.numberOfShotsTaken) of \(Submission.minimumPhotos)+ recommended")
                                    .font(.headline)
                            }
                            LiveScanCoach(snapshot: qualitySnapshot,
                                          event: session.userCompletedScanPass ? "pass-completed" : "",
                                          active: session.state == .capturing && !session.isPaused && session.feedback.isEmpty)
                            controls
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
            Button("Finish anyway") { session.finish() }
            Button("Keep scanning", role: .cancel) {}
        }
        .confirmationDialog("Stop this capture?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Stop capture", role: .destructive) { session.cancel(); model.cancelCapture() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("This capture will end without saving a completed scan.")
        }
        .onChange(of: session.userCompletedScanPass) { _, completed in
            if completed { completedPasses += 1 }
        }
        .onChange(of: session.feedback) { _, _ in
            // Retain quality warnings, but not stale direction/distance instructions.
            observedQualityFeedback.formUnion(qualitySnapshot.feedback.filter { ["dark", "fast"].contains($0) })
        }
        .onChange(of: finished) { _, done in
            if done {
                var saved = qualitySnapshot
                saved.completedPass = completedPasses > 0 || session.userCompletedScanPass
                saved.feedback = Array(observedQualityFeedback).sorted()
                try? ScanQualityFiles.save(saved, named: ScanQualityFiles.snapshotName, folder: folder)
                model.captureFinished(folder: folder)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch session.state {
        case .detecting:
            Button("Start capture") { session.startCapturing() }.buttonStyle(.borderedProminent)
        case .capturing:
            if session.isPaused {
                // beginNewScanPassAfterFlip() is only accepted while paused ("Must be .paused from
                // .capturing"), so flipping is two steps: pause, then continue once it is flipped.
                Button("Object flipped, continue") { session.beginNewScanPassAfterFlip() }.buttonStyle(.borderedProminent)
            } else if session.userCompletedScanPass {
                // One lap is rarely enough for detail. Another lap from a new height, or with the
                // object flipped, fills in the sides and underside.
                Button("Another lap, higher or lower") { session.beginNewScanPass() }.buttonStyle(.bordered)
                Button("Flip the object and scan again") { session.pause() }.buttonStyle(.bordered)
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
        Button(failureMessage == nil ? "Cancel" : "Back", role: .cancel) {
            if session.numberOfShotsTaken > 0 && failureMessage == nil { confirmCancel = true }
            else { session.cancel(); model.cancelCapture() }
        }
        .frame(minHeight: 44)
    }

    private var qualitySnapshot: ScanQualitySnapshot {
        var feedback: [String] = []
        if session.feedback.contains(.movingTooFast) { feedback.append("fast") }
        if session.feedback.contains(.objectTooClose) { feedback.append("close") }
        if session.feedback.contains(.objectTooFar) { feedback.append("far") }
        if session.feedback.contains(.environmentLowLight) || session.feedback.contains(.environmentTooDark) { feedback.append("dark") }
        if session.feedback.contains(.outOfFieldOfView) { feedback.append("outOfView") }
        return .init(mode: .object, photoCount: session.numberOfShotsTaken,
                     completedPass: session.userCompletedScanPass, feedback: feedback,
                     thermal: Diagnostics.sample().thermal)
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
            if session.isPaused { return "Flip the object so the underside faces up, then tap Continue." }
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
