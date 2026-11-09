import Foundation
import RealityKit

/// Builds a USDZ model from the photos a phone sent, using the Mac's own Object Capture
/// (`PhotogrammetrySession`). Needs a Mac with enough GPU memory; older Macs report that
/// through `PhotogrammetrySession.isSupported`.
enum PhotoReconstruction {
    /// `archive` is a zip containing a folder of photos (HEIC, JPG or PNG). Returns the model's URL,
    /// next to the archive. `progress` gets 0...1.
    static func run(archive: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        guard PhotogrammetrySession.isSupported else {
            throw ScanError.message("This Mac cannot build models from photos. Build on the phone instead.")
        }
        let work = archive.deletingLastPathComponent().appending(path: "unpack-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        try await unzip(archive, to: work)
        let photos = try photoFolder(in: work)
        let output = archive.deletingPathExtension().appendingPathExtension("usdz")
        try? FileManager.default.removeItem(at: output)  // a leftover from an earlier failed run

        // Most detail first. `.full` needs a lot of memory, so a failure drops one level and tries again.
        let levels: [PhotogrammetrySession.Request.Detail] = [.full, .medium]
        for (index, detail) in levels.enumerated() {
            do {
                try await build(photos: photos, output: output, detail: detail, progress: progress)
                return output
            } catch is ScanError where index < levels.count - 1 {
                try? FileManager.default.removeItem(at: output)
                continue
            }
        }
        throw ScanError.message("Model building ended without a result.")
    }

    private static func build(photos: URL, output: URL, detail: PhotogrammetrySession.Request.Detail,
                              progress: @escaping (Double) -> Void) async throws {
        var configuration = PhotogrammetrySession.Configuration()
        configuration.featureSensitivity = .high  // picks up fine texture like printed text and page edges
        let session = try PhotogrammetrySession(input: photos, configuration: configuration)
        try session.process(requests: [.modelFile(url: output, detail: detail)])
        for try await result in session.outputs {
            switch result {
            case .requestProgress(_, let fraction): progress(fraction)
            case .requestComplete: return
            case .requestError(_, let error): throw ScanError.message(describe(error))
            case .processingCancelled: throw ScanError.message("Model building was cancelled.")
            default: continue
            }
        }
        throw ScanError.message("Model building ended without a result.")
    }

    /// `PhotogrammetrySession.Error` prints as a bare case name ("processError"); say what to try.
    private static func describe(_ error: Error) -> String {
        let name = "\(error)"
        guard name == "processError" else { return name }
        return "Object Capture could not build a model from these photos. Usually there are too few photos, too little overlap between neighbours, blur, or too little free memory. Take 50+ sharp photos with about 70% overlap and try again."
    }

    /// `ditto` ships with macOS and unpacks the zip a phone produces.
    private static func unzip(_ archive: URL, to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, folder.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ScanError.message("The photo archive could not be opened.") }
        }.value
    }

    /// The folder holding the photos: the unpacked root, or its only subfolder.
    private static func photoFolder(in root: URL) throws -> URL {
        let manager = FileManager.default
        let entries = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if entries.count == 1, (try entries[0].resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { return entries[0] }
        guard !entries.isEmpty else { throw ScanError.message("The photo archive was empty.") }
        return root
    }
}
