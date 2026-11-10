import CoreGraphics
import Foundation
import ImageIO

/// Checks PhotoQuality on generated JPEGs: sharp checkerboards, flat grey frames (no edges, so "blurry")
/// and faint checkerboards (a plain side of the object: little texture, but not blur).
@main struct PhotoQualityCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".build/quality-check", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)

        // 22 sharp + 2 flat: only the flat ones go.
        let many = root.appending(path: "many", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<22 { try write(contrast: 0.5, to: many.appending(path: "IMG_\(String(format: "%04d", i)).jpg")) }
        for i in 22..<24 { try write(contrast: 0, to: many.appending(path: "IMG_\(String(format: "%04d", i)).jpg")) }
        try "0 -1 0".write(to: many.appending(path: "IMG_0022_gravity.TXT"), atomically: true, encoding: .utf8)
        let rejected = root.appending(path: "rejected", directoryHint: .isDirectory)
        let report = try PhotoQuality.filter(photos: many, rejected: rejected)
        guard report.total == 24, report.kept == 22, report.droppedBlurry == 2 else { throw fail("expected 2 of 24 dropped, got \(report)") }
        let moved = try FileManager.default.contentsOfDirectory(atPath: rejected.path).sorted()
        guard moved == ["IMG_0022.jpg", "IMG_0022_gravity.TXT", "IMG_0023.jpg"] else { throw fail("rejected folder holds \(moved)") }

        // A small capture is never thinned, blurry or not.
        let few = root.appending(path: "few", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: few, withIntermediateDirectories: true)
        for i in 0..<9 { try write(contrast: 0.5, to: few.appending(path: "IMG_\(i).jpg")) }
        try write(contrast: 0, to: few.appending(path: "IMG_9.jpg"))
        let small = try PhotoQuality.filter(photos: few, rejected: root.appending(path: "rejected-few", directoryHint: .isDirectory))
        guard small.total == 10, small.kept == 10 else { throw fail("a small capture was thinned: \(small)") }

        // A stretch of plain views (a lap over a bare table, the blank back of a book) is soft compared
        // with the rest of the capture but not with its neighbours. Dropping it would leave a hole.
        let plain = root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        for i in 0..<20 { try write(contrast: 0.5, to: plain.appending(path: "IMG_\(String(format: "%04d", i)).jpg")) }
        for i in 20..<30 { try write(contrast: 0.05, to: plain.appending(path: "IMG_\(String(format: "%04d", i)).jpg")) }
        let stretch = try PhotoQuality.filter(photos: plain, rejected: root.appending(path: "rejected-plain", directoryHint: .isDirectory))
        guard stretch.total == 30, stretch.kept == 30 else { throw fail("a stretch of plain views was thinned: \(stretch)") }
        print("Photo quality check passed")
    }

    static func fail(_ message: String) -> Error { NSError(domain: "PhotoQualityCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    /// A grey frame with a checkerboard `contrast` brighter than it. 0 is flat grey.
    static func write(contrast: Double, to url: URL) throws {
        let width = 640, height = 480
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw fail("no context") }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if contrast > 0 {
            context.setFillColor(gray: 0.5 + contrast, alpha: 1)
            for row in 0..<(height / 8) { for column in 0..<(width / 8) where (row + column) % 2 == 0 {
                context.fill(CGRect(x: column * 8, y: row * 8, width: 8, height: 8))
            } }
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { throw fail("no image") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw fail("could not write \(url.lastPathComponent)") }
    }
}
