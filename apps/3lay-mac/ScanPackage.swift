import CoreGraphics
import Foundation
import ImageIO
import simd

/// Packs the scan on the plate into a zip for an AI coding agent: the mesh, straight-on pictures with
/// their scale, measurements, some of the photos, and the `scan-to-part` skill that tells the agent
/// how to rebuild the scan as a clean part and check its work. 3lay Mac itself calls no AI service.
enum ScanPackage {
    static let format = "3lay-scan-package/1"
    static let viewPixels = 768
    static let maxPhotos = 16
    static let photoPixels = 1600

    struct Manifest: Codable {
        struct Bounds: Codable {
            var min: [Float]
            var max: [Float]
            var size: [Float]
        }
        struct View: Codable {
            var name: String
            var file: String
            var caption: String
            /// The picture is `pixels` × `pixels` and shows `spanMm` × `spanMm` millimetres around `centre`.
            var pixels: Int
            var spanMm: Float
            var mmPerPixel: Float
            var centre: [Float]
            var right: [Float]
            var up: [Float]
            var toward: [Float]
        }
        var format: String
        var createdAt: String
        var units: String
        var up: String
        /// What the object is, in the user's words.
        var note: String
        var source: String
        var mesh: String
        var triangles: Int
        var bounds: Bounds
        var views: [View]
        var photos: [String]
    }

    /// The skill folder inside the app.
    static var bundledSkill: URL? {
        guard let url = Bundle.main.resourceURL?.appending(path: "skill/scan-to-part", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: url.appending(path: "SKILL.md").path) else { return nil }
        return url
    }

    /// Writes the package to `zip`. `mesh` must already be in millimetres. `photos` is a folder of
    /// JPEGs from `savePhotos`, when the scan was built from photos on this Mac.
    static func write(mesh: Mesh, note: String, photos: URL?, skill: URL, to zip: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            let work = manager.temporaryDirectory.appending(path: "3lay-package-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? manager.removeItem(at: work) }
            let root = work.appending(path: zip.deletingPathExtension().lastPathComponent, directoryHint: .isDirectory)
            let scan = root.appending(path: "scan", directoryHint: .isDirectory)
            try manager.createDirectory(at: scan.appending(path: "views"), withIntermediateDirectories: true)

            try mesh.saveSTL(scan.appending(path: "scan.stl"), scale: 1, angle: 0)
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            for vertex in mesh.vertices { lo = simd_min(lo, vertex); hi = simd_max(hi, vertex) }
            let centre = (lo + hi) / 2
            let span = Swift.max(simd_length(hi - lo) * 1.08, 1e-3)
            func list(_ v: SIMD3<Float>) -> [Float] { [v.x, v.y, v.z] }

            var views: [Manifest.View] = []
            for view in MeshRender.views {
                let file = "views/\(view.name).png"
                guard let png = MeshRender.png(MeshRender.render(mesh, view: view, centre: centre, span: span, size: viewPixels), size: viewPixels)
                else { throw ScanError.message("Could not draw the \(view.name) view.") }
                try png.write(to: scan.appending(path: file))
                views.append(Manifest.View(
                    name: view.name, file: file, caption: view.caption, pixels: viewPixels, spanMm: span, mmPerPixel: span / Float(viewPixels),
                    centre: list(centre), right: list(view.right), up: list(view.up), toward: list(view.toward)))
            }

            var photoNames: [String] = []
            if let photos, let files = try? manager.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil) {
                let jpegs = files.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                if !jpegs.isEmpty { try manager.createDirectory(at: scan.appending(path: "photos"), withIntermediateDirectories: true) }
                for jpeg in jpegs {
                    try manager.copyItem(at: jpeg, to: scan.appending(path: "photos/\(jpeg.lastPathComponent)"))
                    photoNames.append("photos/\(jpeg.lastPathComponent)")
                }
            }

            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let manifest = Manifest(
                format: format, createdAt: ISO8601DateFormatter().string(from: Date()), units: "mm", up: "+Z",
                note: trimmed, source: mesh.name, mesh: "scan.stl", triangles: mesh.faces.count,
                bounds: .init(min: list(lo), max: list(hi), size: list(hi - lo)), views: views, photos: photoNames)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(to: scan.appending(path: "scan.json"))

            try manager.createDirectory(at: root.appending(path: "skill"), withIntermediateDirectories: true)
            try manager.copyItem(at: skill, to: root.appending(path: "skill/scan-to-part"))
            try readme(manifest).write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
            // Agents look for their own instruction file: AGENTS.md is read by Codex (ChatGPT's coding
            // agent) and many others, CLAUDE.md by Claude Code. Both point at the same skill.
            try agentInstructions(manifest).write(to: root.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
            try "@AGENTS.md\n".write(to: root.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)

            try? manager.removeItem(at: zip)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", root.path, zip.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ScanError.message("The package could not be zipped.") }
        }.value
    }

    /// The prompt the user pastes into their agent, and what the agent needs.
    static func prompt(note: String) -> String {
        var text = "Use the skill in skill/scan-to-part/SKILL.md to rebuild the scan in scan/ as a clean, printable part."
        if !note.isEmpty { text += " The object is: \(note)." }
        return text
    }

    private static func agentInstructions(_ manifest: Manifest) -> String {
        """
        # Scan package

        This folder is a 3D scan from 3lay Mac. To rebuild it as a clean part, read and follow
        `skill/scan-to-part/SKILL.md`. Start with `README.md` and `scan/scan.json`.

        - Never change anything under `scan/`.
        - Work in this folder and write `part.scad` and `part.stl` here.
        - Lengths are millimetres, Z is up.
        \(manifest.note.isEmpty ? "" : "\nWhat it is, in the owner's words: \(manifest.note)\n")
        """
    }

    /// How to start each kind of agent in the unzipped folder.
    static let agents: [(name: String, steps: String)] = [
        ("Claude Code", "Open Terminal in the unzipped folder and run `claude`."),
        ("Codex (ChatGPT)", "Open Terminal in the unzipped folder and run `codex`, or open the folder in the Codex app. It needs a ChatGPT plan or an OpenAI API key."),
        ("Another agent", "Open the folder in any coding agent that can read files and run commands. It reads `AGENTS.md`; if it does not, paste the prompt."),
    ]

    private static func readme(_ manifest: Manifest) -> String {
        let size = manifest.bounds.size.map { String(format: "%.1f", Double($0)) }.joined(separator: " × ")
        return """
            # Scan package from 3lay Mac

            A 3D scan, packed for an AI coding agent to rebuild as a clean, editable part.

            - Scan: `scan/scan.stl`, \(manifest.triangles) triangles, \(size) mm, Z up
            - What it is: \(manifest.note.isEmpty ? "(not described)" : manifest.note)
            - Pictures with scale: `scan/views/`\(manifest.photos.isEmpty ? "" : "\n- Photos: `scan/photos/` (\(manifest.photos.count))")

            ## How to use it

            1. Unzip this folder and open it in an AI coding agent that can read files and run commands:
            \(agents.map { "   - **\($0.name):** \($0.steps)" }.joined(separator: "\n"))

               A chat window that cannot run commands on your files, such as the ChatGPT website, cannot do the
               compare-and-fix loop; use one of the agents above.
            2. Paste this prompt:

               > \(prompt(note: manifest.note))

            3. The agent writes `part.scad` and `part.stl` and reports how closely they match the scan.
               Open `part.stl` in 3lay Mac with **Import file**, or straight in your slicer.

            The agent needs Python 3 with numpy and the `openscad` command (`brew install openscad`).

            This works well for mechanical parts: brackets, enclosures, knobs. A figurine or anything
            sculpted is better printed from the scan itself.

            """
    }

    /// Saves up to `maxPhotos` evenly spaced photos from a capture as small JPEGs, so a package can
    /// include them after the originals (hundreds of megabytes) are gone. Returns how many were saved.
    static func savePhotos(from folder: URL, to destination: URL) -> Int {
        let manager = FileManager.default
        let extensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]
        let images = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !images.isEmpty else { return 0 }
        try? manager.removeItem(at: destination)
        guard (try? manager.createDirectory(at: destination, withIntermediateDirectories: true)) != nil else { return 0 }
        let count = Swift.min(maxPhotos, images.count)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: photoPixels,
        ]
        var saved = 0
        for index in 0..<count {
            let url = images[index * images.count / count]
            let target = destination.appending(path: String(format: "%02d.jpg", saved + 1))
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let output = CGImageDestinationCreateWithURL(target as CFURL, "public.jpeg" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(output) { saved += 1 }
        }
        return saved
    }
}
