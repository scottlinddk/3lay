import CoreGraphics
import Foundation
import ImageIO

/// Writes a scan package for a small box, unpacks it and checks what an agent will find inside.
/// The unpacked folder stays in `.build/package-check/` so `rebuild_check` can run the skill's tool on it.
@main struct PackageCheck {
    static func fail(_ message: String) -> Error { NSError(domain: "PackageCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    static func main() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: manager.currentDirectoryPath).appending(path: ".build/package-check", directoryHint: .isDirectory)
        try? manager.removeItem(at: root)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        // A 40 × 30 × 20 mm box, standing on the plate.
        let obj = root.appending(path: "box.obj")
        try "v 0 0 0\nv 40 0 0\nv 40 30 0\nv 0 30 0\nv 0 0 20\nv 40 0 20\nv 40 30 20\nv 0 30 20\nf 1 4 3 2\nf 5 6 7 8\nf 1 2 6 5\nf 3 4 8 7\nf 2 3 7 6\nf 4 1 5 8\n"
            .write(to: obj, atomically: true, encoding: .utf8)
        let mesh = try Mesh.load(obj)

        // Twenty capture photos become at most sixteen small ones.
        let capture = root.appending(path: "capture", directoryHint: .isDirectory)
        try manager.createDirectory(at: capture, withIntermediateDirectories: true)
        for i in 0..<20 { try writePhoto(capture.appending(path: String(format: "IMG_%04d.jpg", i))) }
        let photos = root.appending(path: "kept.photos", directoryHint: .isDirectory)
        guard ScanPackage.savePhotos(from: capture, to: photos) == ScanPackage.maxPhotos else { throw fail("photos were not thinned to \(ScanPackage.maxPhotos)") }

        let skill = URL(fileURLWithPath: manager.currentDirectoryPath).appending(path: "skill/scan-to-part", directoryHint: .isDirectory)
        let zip = root.appending(path: "Box scan package.zip")
        try await ScanPackage.write(mesh: mesh, note: "test box", photos: photos, skill: skill, to: zip)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, root.appending(path: "unpacked").path]
        try process.run()
        process.waitUntilExit()
        let package = root.appending(path: "unpacked/Box scan package", directoryHint: .isDirectory)
        for file in ["README.md", "AGENTS.md", "CLAUDE.md", "scan/scan.stl", "scan/scan.json", "scan/views/top.png", "scan/views/front.png", "scan/views/right.png", "scan/views/corner.png",
                     "scan/photos/01.jpg", "scan/photos/16.jpg", "skill/scan-to-part/SKILL.md", "skill/scan-to-part/tools/scan_tools.py"] {
            guard manager.fileExists(atPath: package.appending(path: file).path) else { throw fail("the package has no \(file)") }
        }
        let manifest = try JSONDecoder().decode(ScanPackage.Manifest.self, from: Data(contentsOf: package.appending(path: "scan/scan.json")))
        guard manifest.format == ScanPackage.format, manifest.units == "mm", manifest.note == "test box", manifest.triangles == 12,
              manifest.bounds.size == [40, 30, 20], manifest.bounds.min[2] == 0, manifest.views.count == 4, manifest.photos.count == 16,
              manifest.views.allSatisfy({ $0.pixels == ScanPackage.viewPixels && abs($0.mmPerPixel * Float($0.pixels) - $0.spanMm) < 0.001 })
        else { throw fail("scan.json is wrong: \(manifest)") }
        guard try Mesh.load(package.appending(path: "scan/scan.stl")).faces.count == 12 else { throw fail("scan.stl does not load") }
        let readme = try String(contentsOf: package.appending(path: "README.md"), encoding: .utf8)
        guard readme.contains(ScanPackage.prompt(note: "test box")), readme.contains("40.0 × 30.0 × 20.0 mm"),
              readme.contains("`claude`"), readme.contains("`codex`") else { throw fail("README.md has no prompt, size or agent steps") }
        let agents = try String(contentsOf: package.appending(path: "AGENTS.md"), encoding: .utf8)
        guard agents.contains("skill/scan-to-part/SKILL.md"), agents.contains("test box"),
              try String(contentsOf: package.appending(path: "CLAUDE.md"), encoding: .utf8).contains("@AGENTS.md") else { throw fail("agent instruction files are wrong") }

        // The top view shows the box in the middle and nothing in the corner.
        let size = ScanPackage.viewPixels
        let top = MeshRender.render(mesh, view: MeshRender.views[0], centre: SIMD3(0, 0, 10), span: manifest.views[0].spanMm, size: size)
        guard top[size / 2 * size + size / 2] < 255, top[0] == 255 else { throw fail("the top view is wrong") }
        print("Scan package check passed")
    }

    static func writePhoto(_ url: URL) throws {
        guard let context = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { throw fail("no photo") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw fail("could not write \(url.lastPathComponent)") }
    }
}
