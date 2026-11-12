#if os(iOS)
import Foundation
import RealityKit

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
        try await ScanAdvisor.runner.withSuspended {
            try await reconstruct(imagesDirectory: imagesDirectory, output: output, progress: progress)
        }
    }

    private static func reconstruct(imagesDirectory: URL, output: URL,
                                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let session = try PhotogrammetrySession(input: imagesDirectory)
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
    }
}
#endif
