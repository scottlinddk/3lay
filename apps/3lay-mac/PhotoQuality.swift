import CoreGraphics
import Foundation
import ImageIO

/// Looks at the photos a phone sent before Object Capture does. Blurry frames make the model
/// soft and noisy, so the worst ones are set aside. It also counts how many photos carry LiDAR depth,
/// which Object Capture uses for scale and for surfaces with little texture (like blank pages).
enum PhotoQuality {
    struct Report: Equatable {
        let total: Int
        let kept: Int
        /// Photos with depth in the file or in a `_depth` file beside it.
        let withDepth: Int
        var droppedBlurry: Int { total - kept }
    }

    /// Never go below this many photos: fewer overlap too little to build a model.
    static let minimumKept = 20
    /// Never set aside more than this share of the photos.
    static let maxDropShare = 25
    /// A photo is blurry when its sharpness is under this fraction of the median photo's.
    static let blurRatio = 0.4

    private static let photoExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png"]

    /// Moves the blurriest photos (and files named after them, like `IMG_0001_gravity.TXT`) from
    /// `photos` into `rejected`. Returns what was found.
    static func filter(photos: URL, rejected: URL) throws -> Report {
        let manager = FileManager.default
        let all = try manager.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil)
        let images = all.filter { photoExtensions.contains($0.pathExtension.lowercased()) }
        var scored: [(url: URL, score: Double)] = []
        var withDepth = 0
        for image in images {
            guard let source = CGImageSourceCreateWithURL(image as CFURL, nil) else { continue }
            if hasDepth(source) || hasDepthSidecar(image, among: all) { withDepth += 1 }
            if let score = sharpness(of: source) { scored.append((image, score)) }
        }
        guard scored.count > minimumKept else { return Report(total: images.count, kept: images.count, withDepth: withDepth) }

        let sorted = scored.sorted { $0.score < $1.score }
        let median = sorted[sorted.count / 2].score
        let allowed = min(scored.count * maxDropShare / 100, scored.count - minimumKept)
        let blurry = sorted.prefix(allowed).filter { $0.score < median * blurRatio }
        if !blurry.isEmpty { try manager.createDirectory(at: rejected, withIntermediateDirectories: true) }
        for photo in blurry {
            let stem = photo.url.deletingPathExtension().lastPathComponent
            for file in all where file.lastPathComponent == photo.url.lastPathComponent
                || file.lastPathComponent.hasPrefix(stem + "_") || file.deletingPathExtension().lastPathComponent == stem {
                try? manager.moveItem(at: file, to: rejected.appending(path: file.lastPathComponent))
            }
        }
        return Report(total: images.count, kept: images.count - blurry.count, withDepth: withDepth)
    }

    private static func hasDepth(_ source: CGImageSource) -> Bool {
        CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity) != nil
    }

    private static func hasDepthSidecar(_ image: URL, among files: [URL]) -> Bool {
        let stem = image.deletingPathExtension().lastPathComponent
        return files.contains { $0.lastPathComponent.lowercased().hasPrefix((stem + "_depth").lowercased()) }
    }

    /// Variance of the Laplacian on a small grayscale copy: sharp edges give a large value, blur a small one.
    /// Only meaningful compared with other photos from the same capture.
    static func sharpness(of source: CGImageSource) -> Double? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = image.width, height = image.height
        guard width > 2, height > 2 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var sum = 0.0, sumOfSquares = 0.0, count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let laplacian = 4 * Int(pixels[i]) - Int(pixels[i - 1]) - Int(pixels[i + 1]) - Int(pixels[i - width]) - Int(pixels[i + width])
                let value = Double(laplacian)
                sum += value
                sumOfSquares += value * value
                count += 1
            }
        }
        let mean = sum / count
        return sumOfSquares / count - mean * mean
    }
}
