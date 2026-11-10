import Foundation

/// Unpacks a LiDAR scan bundle from the phone (`*.lidar.zip`, format `3lay-lidar/1`): an ARKit mesh
/// as a binary PLY in meters, Z up, plus photos with camera poses. The mesh is imported as is.
/// The photos are kept next to it with their poses, ready for texturing or refinement later; nothing
/// on the Mac uses them yet.
enum LidarImport {
    struct Unpacked {
        /// The extracted bundle folder (photos, manifest, mesh).
        let folder: URL
        let mesh: URL
        let photoCount: Int
    }

    /// Just the parts of `manifest.json` the Mac needs. `Photo` ignores everything inside each entry.
    private struct Manifest: Decodable {
        struct Photo: Decodable {}
        let format: String
        let meshFile: String
        let photos: [Photo]
    }

    static let formatPrefix = "3lay-lidar/"

    /// Unzips next to the archive and returns the mesh to import. Removes the zip when done.
    static func unpack(archive: URL) async throws -> Unpacked {
        let work = archive.deletingPathExtension().appendingPathExtension("unpacked")
        try? FileManager.default.removeItem(at: work)
        try await PhotoReconstruction.unzip(archive, to: work)
        let root = try bundleRoot(in: work)
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appending(path: "manifest.json")))
        } catch { throw ScanError.message("The LiDAR scan has no readable manifest.json.") }
        guard manifest.format.hasPrefix(formatPrefix) else {
            throw ScanError.message("This is not a 3lay LiDAR scan (format \(manifest.format)).")
        }
        // The phone names the mesh file, so make sure it cannot point outside the bundle.
        let mesh = root.appending(path: manifest.meshFile).standardizedFileURL
        guard mesh.path.hasPrefix(root.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: mesh.path) else {
            throw ScanError.message("The LiDAR scan has no mesh file.")
        }
        try? FileManager.default.removeItem(at: archive)
        return Unpacked(folder: root, mesh: mesh, photoCount: manifest.photos.count)
    }

    /// The folder holding `manifest.json`: the unpacked root, or its only subfolder.
    private static func bundleRoot(in work: URL) throws -> URL {
        let manager = FileManager.default
        if manager.fileExists(atPath: work.appending(path: "manifest.json").path) { return work }
        let entries = try manager.contentsOfDirectory(at: work, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
        if entries.count == 1, manager.fileExists(atPath: entries[0].appending(path: "manifest.json").path) { return entries[0] }
        throw ScanError.message("The LiDAR scan has no manifest.json.")
    }
}
