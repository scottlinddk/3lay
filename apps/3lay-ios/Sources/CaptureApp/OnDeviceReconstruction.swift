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
    static func run(imagesDirectory: URL, output: URL) async throws {
        let session = try PhotogrammetrySession(input: imagesDirectory)
        try session.process(requests: [.modelFile(url: output, detail: .reduced)])
        for try await result in session.outputs {
            switch result {
            case .requestComplete: return
            case .requestError(_, let error): throw OnDeviceError.failed("\(error)")
            case .processingCancelled: throw OnDeviceError.failed("cancelled")
            default: continue
            }
        }
        throw OnDeviceError.failed("session ended without a result")
    }
}
#endif
