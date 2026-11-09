import Foundation

public enum BundleError: Error, Equatable {
    case noImages
}

public enum BundleWriter {
    static let imageExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]

    /// Lists capture images in a stable order.
    public static func images(in directory: URL) throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return all
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Hashes the images and writes `manifest.json` beside them. Returns the manifest URL.
    @discardableResult
    public static func write(
        imagesDirectory: URL, device: CaptureManifest.Device, now: Date = Date()
    ) throws -> (manifest: CaptureManifest, url: URL) {
        let urls = try images(in: imagesDirectory)
        guard !urls.isEmpty else { throw BundleError.noImages }
        let files = try urls.map { url -> CaptureManifest.File in
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            return .init(path: url.lastPathComponent, sha256: try Hashing.sha256(of: url), bytes: size)
        }
        let scale = CaptureManifest.Scale(
            declaredUnits: device.hasLiDAR ? "meters" : "unknown",
            provenance: device.hasLiDAR ? "sensor-lidar" : "none")
        let manifest = CaptureManifest(createdAt: now, device: device, scale: scale, images: files)
        let out = imagesDirectory.appendingPathComponent("manifest.json")
        try CaptureManifest.encoder().encode(manifest).write(to: out, options: .atomic)
        return (manifest, out)
    }
}
