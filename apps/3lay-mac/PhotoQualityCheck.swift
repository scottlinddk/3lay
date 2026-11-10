import CoreGraphics
import Foundation
import ImageIO

/// Checks PhotoQuality on generated JPEGs: sharp checkerboards and flat grey frames (no edges, so "blurry").
@main struct PhotoQualityCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".build/quality-check", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)

        // 22 sharp + 2 flat: only the flat ones go.
        let many = root.appending(path: "many", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<22 { try write(sharp: true, to: many.appending(path: "IMG_\(String(format: "%04d", i)).jpg")) }
        for i in 22..<24 { try write(sharp: false, to: many.appending(path: "IMG_\(String(format: "%04d", i)).jpg")) }
        try "0 -1 0".write(to: many.appending(path: "IMG_0022_gravity.TXT"), atomically: true, encoding: .utf8)
        let rejected = root.appending(path: "rejected", directoryHint: .isDirectory)
        let report = try PhotoQuality.filter(photos: many, rejected: rejected)
        guard report.total == 24, report.kept == 22, report.droppedBlurry == 2 else { throw fail("expected 2 of 24 dropped, got \(report)") }
        let moved = try FileManager.default.contentsOfDirectory(atPath: rejected.path).sorted()
        guard moved == ["IMG_0022.jpg", "IMG_0022_gravity.TXT", "IMG_0023.jpg"] else { throw fail("rejected folder holds \(moved)") }

        // A small capture is never thinned, blurry or not.
        let few = root.appending(path: "few", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: few, withIntermediateDirectories: true)
        for i in 0..<9 { try write(sharp: true, to: few.appending(path: "IMG_\(i).jpg")) }
        try write(sharp: false, to: few.appending(path: "IMG_9.jpg"))
        let small = try PhotoQuality.filter(photos: few, rejected: root.appending(path: "rejected-few", directoryHint: .isDirectory))
        guard small.total == 10, small.kept == 10 else { throw fail("a small capture was thinned: \(small)") }
        print("Photo quality check passed")
    }

    static func fail(_ message: String) -> Error { NSError(domain: "PhotoQualityCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    static func write(sharp: Bool, to url: URL) throws {
        let width = 640, height = 480
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw fail("no context") }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if sharp {
            context.setFillColor(gray: 1, alpha: 1)
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
