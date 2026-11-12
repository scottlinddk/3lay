#if os(iOS)
import Foundation
import RealityKit
import UIKit
import os

enum OnDeviceError: LocalizedError {
    case failed(String)

    /// Without this, `localizedDescription` is the opaque "(CaptureApp.OnDeviceError error 0.)".
    var errorDescription: String? {
        switch self {
        case .failed(let reason): return "Building the 3D model on this phone failed (\(reason))."
        }
    }
}

/// Runs PhotogrammetrySession on the phone. `.reduced` keeps memory and time sane; the iOS SDK has no `.medium`.
enum OnDeviceReconstruction {
    /// `progress` gets 0...1 as the model is built.
    /// Cancelling the calling task cancels the session, deletes the partial model and throws `CancellationError`.
    static func run(imagesDirectory: URL, output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        // Auto-lock backgrounds the app, and iOS refuses GPU work from a backgrounded app, which ends the build.
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        defer { Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false } }
        try await ScanAdvisor.runner.withSuspended {
            try await reconstruct(imagesDirectory: imagesDirectory, output: output, progress: progress)
        }
    }

    private static func reconstruct(imagesDirectory: URL, output: URL,
                                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let session = try PhotogrammetrySession(input: imagesDirectory)
        // The build cannot continue in the background (no GPU access there). Stop it and say why, instead of
        // letting it fail later with an opaque Metal error.
        let wentToBackground = OSAllocatedUnfairLock(initialState: false)
        nonisolated(unsafe) let building = session
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in
            wentToBackground.withLock { $0 = true }
            building.cancel()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        do {
            try await withTaskCancellationHandler {
                try session.process(requests: [.modelFile(url: output, detail: .reduced)])
                for try await result in session.outputs {
                    switch result {
                    case .requestProgress(_, let fraction): progress(fraction)
                    case .requestComplete: return
                    case .requestError(_, let error):
                        if Task.isCancelled { throw CancellationError() }
                        throw OnDeviceError.failed("\(error)")
                    case .processingCancelled: throw CancellationError()
                    default: continue
                    }
                }
                if Task.isCancelled { throw CancellationError() }
                throw OnDeviceError.failed("session ended without a result")
            } onCancel: {
                session.cancel()
            }
        } catch where wentToBackground.withLock({ $0 }) && !Task.isCancelled {
            throw OnDeviceError.failed("the app moved to the background. Keep it open while the model is built")
        }
    }
}
#endif
