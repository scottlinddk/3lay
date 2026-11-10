import Foundation
import RealityKit

/// Builds a USDZ model from the photos a phone sent, using the Mac's own Object Capture
/// (`PhotogrammetrySession`). Needs a Mac with enough GPU memory; older Macs report that
/// through `PhotogrammetrySession.isSupported`.
enum PhotoReconstruction {
    /// The model and the detail level it was really built at, which can be lower than requested.
    struct Built {
        let url: URL
        let detail: String
        /// Photos used, blurry ones set aside, and how many carry LiDAR depth.
        let quality: PhotoQuality.Report
        /// Set when a higher level failed first, so the user knows why the model is coarser.
        let fallbackNote: String?
    }

    /// One attempt: an Object Capture detail level and, for `.custom`, its triangle budget.
    private struct Level {
        let name: String
        let detail: PhotogrammetrySession.Request.Detail
        let polygons: UInt?
    }

    /// Triangle budgets for the model. The preset levels stop at 250k triangles (`.full`) and keep
    /// finer detail only in texture maps, which an STL throws away. For printing the detail has to
    /// be in the geometry, so the model is built at a custom level (macOS 14) with a larger budget.
    /// Both stay well inside what `Mesh.load` accepts (10M triangles, 500 MB of STL).
    static let printPolygons: UInt = 1_000_000
    static let maximumPolygons: UInt = 3_000_000

    /// Most detail first. A level that fails (usually for lack of memory) drops to the next one.
    private static func levels(maximumDetail: Bool) -> [Level] {
        let budget = maximumDetail ? maximumPolygons : printPolygons
        return [
            Level(name: "\(budget / 1_000_000)M-triangle", detail: .custom, polygons: budget),
            Level(name: "Full", detail: .full, polygons: nil),
            Level(name: "Medium", detail: .medium, polygons: nil),
        ]
    }

    /// `archive` is a zip containing a folder of photos (HEIC, JPG or PNG). Returns the model's URL,
    /// next to the archive. `progress` gets 0...1. `maximumDetail` asks for the larger triangle budget.
    static func run(archive: URL, maximumDetail: Bool = false, progress: @escaping (Double) -> Void) async throws -> Built {
        guard PhotogrammetrySession.isSupported else {
            throw ScanError.message("This Mac cannot build models from photos. Build on the phone instead.")
        }
        let work = archive.deletingLastPathComponent().appending(path: "unpack-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: work) }
        try await unzip(archive, to: work)
        let photos = try photoFolder(in: work)
        // Blurry frames soften the model, so set the worst aside before Object Capture reads the folder.
        let rejected = archive.deletingLastPathComponent().appending(path: "rejected-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: rejected) }
        let quality = try await Task.detached(priority: .userInitiated) {
            try PhotoQuality.filter(photos: photos, rejected: rejected)
        }.value
        let output = archive.deletingPathExtension().appendingPathExtension("usdz")
        try? FileManager.default.removeItem(at: output)  // a leftover from an earlier failed run

        let levels = levels(maximumDetail: maximumDetail)
        var note: String?
        for (index, level) in levels.enumerated() {
            do {
                try await build(photos: photos, output: output, level: level, progress: progress)
                return Built(url: output, detail: level.name, quality: quality, fallbackNote: note)
            } catch where index < levels.count - 1 {
                // Any failure drops a level, also one thrown while the session is being set up.
                note = "\(level.name) failed (\(error.localizedDescription))"
                try? FileManager.default.removeItem(at: output)
                continue
            }
        }
        throw ScanError.message("Model building ended without a result.")
    }

    private static func build(photos: URL, output: URL, level: Level, progress: @escaping (Double) -> Void) async throws {
        var configuration = PhotogrammetrySession.Configuration()
        configuration.featureSensitivity = .high  // picks up fine texture like printed text and page edges
        if let polygons = level.polygons {
            configuration.customDetailSpecification.maximumPolygonCount = polygons
            // Only the shape ends up in the STL, so do not spend memory on large texture maps.
            configuration.customDetailSpecification.outputTextureMaps = .diffuseColor
            configuration.customDetailSpecification.maximumTextureDimension = .oneK
        }
        let session = try PhotogrammetrySession(input: photos, configuration: configuration)
        try session.process(requests: [.modelFile(url: output, detail: level.detail)])
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
    static func unzip(_ archive: URL, to folder: URL) async throws {
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
