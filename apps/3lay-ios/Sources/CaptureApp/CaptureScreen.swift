#if os(iOS)
import CaptureKit
import RealityKit
import SwiftUI

/// Guided Object Capture. Photos land in a per-capture folder that survives app restarts.
///
/// This wrapper only exists so a stuck camera can be restarted: bumping `attempt` replaces the whole
/// inner screen, and with it the `ObjectCaptureSession`, the folder and every piece of state.
struct CaptureScreen: View {
    @State private var attempt = 0

    var body: some View {
        ActiveCaptureScreen(restart: { attempt += 1 }).id(attempt)
    }
}

/// Owns the session. A `@StateObject` builds it exactly once; a `@State` default value would construct a
/// throwaway `ObjectCaptureSession` every time the parent rebuilds this view's struct.
@MainActor
private final class CaptureSessionHolder: ObservableObject {
    let session = ObjectCaptureSession()
}

private struct ActiveCaptureScreen: View {
    let restart: () -> Void
    @EnvironmentObject var model: AppModel
    @StateObject private var holder = CaptureSessionHolder()
    @State private var folder = ActiveCaptureScreen.newFolder()
    /// The camera never became usable (no frames, or `startDetecting()` kept being refused).
    @State private var stuck = false
    @State private var started = false
    @Environment(\.scenePhase) private var scenePhase
    private var session: ObjectCaptureSession { holder.session }
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
        .onChange(of: scenePhase) { _, phase in if phase == .active { start() } }
        .task { await watchForStall() }
        .onChange(of: session.state) { _, state in
            // The object box still needs framing, but the first tap on "Detect" adds nothing.
            if state == .ready { Task { await beginDetecting() } }
            if state != .initializing && state != .ready { stuck = false }
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
        case .ready where !stuck:
            // Manual fallback if the automatic attempt below never succeeds.
            Button("Continue") { Task { await beginDetecting() } }.buttonStyle(.borderedProminent)
        case .failed:
            EmptyView()
        default:
            if stuck {
                Button("Restart camera") {
                    session.cancel()
                    try? FileManager.default.removeItem(at: folder)
                    restart()
                }.buttonStyle(.borderedProminent)
            } else {
                ProgressView()
            }
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
        default:
            if stuck { return "The camera did not start. Close other camera apps, then restart the camera." }
            return "Getting ready..."
        }
    }

    /// `state` turns `.ready` slightly before the session accepts `startDetecting()` (the log says
    /// "called in wrong state=running"). A single call is silently rejected and the screen stays on
    /// "Getting ready..." forever, so retry briefly until it is accepted. If it never is, say so.
    private func beginDetecting() async {
        stuck = false
        for _ in 0..<20 {
            guard session.state == .ready else { return }
            if session.startDetecting() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if session.state == .ready { stuck = true }
    }

    /// ARKit stops delivering camera frames when its delegate holds on to too many, and the session then
    /// sits in `.initializing` or `.ready` with a black preview. Give it a generous 20 s, then offer a restart.
    private func watchForStall() async {
        try? await Task.sleep(for: .seconds(20))
        guard !Task.isCancelled else { return }
        if session.state == .initializing || session.state == .ready { stuck = true }
    }

    private func start() {
        // Starting while the app is inactive (permission alert, Control Center, still launching) gets the
        // camera and Metal refused: "Insufficient Permission (to submit GPU work from background)". Wait for
        // `.active`; the scenePhase observer calls this again.
        guard scenePhase == .active, !started else { return }
        // onAppear can fire again; a second start() on a running session fails.
        guard session.state == .initializing else { return }
        started = true
        let images = folder.appendingPathComponent("Images")
        try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var config = ObjectCaptureSession.Configuration()
        // Keeps extra photos beyond what the phone's live guidance asks for. The Mac uses them all,
        // which is what makes a sharper model than a single lap around the object.
        config.isOverCaptureEnabled = true
        config.checkpointDirectory = folder.appendingPathComponent("Checkpoint")
        session.start(imagesDirectory: images, configuration: config)
    }

    fileprivate static func newFolder() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("captures/\(UUID().uuidString)")
    }
}
#endif
