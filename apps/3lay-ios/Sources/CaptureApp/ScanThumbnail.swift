#if os(iOS)
import CaptureKit
import ImageIO
import SwiftUI
import UIKit

/// A small preview of a scan from its first photo, decoded at thumbnail size so a list of scans does
/// not hold full camera images in memory.
enum ScanThumbnail {
    static func load(folder: URL, kind: ScanRecord.Kind, maxPixels: Int = 320) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            let directory = folder.appendingPathComponent(kind == .lidar ? "photos" : "Images")
            guard let first = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter({ !$0.hasPrefix(".") }).sorted().first,
                let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(first) as CFURL, nil)
            else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
    }

    /// Photos in the scan, counted from disk (the object-capture records do not store a count).
    static func photoCount(folder: URL, kind: ScanRecord.Kind) -> Int {
        let directory = folder.appendingPathComponent(kind == .lidar ? "photos" : "Images")
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }
}

/// Rounded thumbnail with a placeholder while it loads (or when the scan has no photo).
struct ScanThumbnailView: View {
    let folder: URL
    let kind: ScanRecord.Kind
    var size: CGFloat = 56
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: kind == .lidar ? "viewfinder" : "cube")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
        .task(id: folder) { image = await ScanThumbnail.load(folder: folder, kind: kind, maxPixels: Int(size * 3)) }
    }
}
#endif
