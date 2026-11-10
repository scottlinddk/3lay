import CoreGraphics
import Foundation
import ImageIO
import simd

/// Draws a mesh as a shaded picture seen straight on, without perspective, so that sizes can be read
/// off it. These pictures are what the AI rebuild shows Claude: the scan, and each attempt at a clean part.
enum MeshRender {
    struct View {
        let name: String
        /// What the picture shows, in words, for the prompt.
        let caption: String
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        /// From the object towards the viewer.
        let toward: SIMD3<Float>
    }

    static let views: [View] = {
        let slanted = simd_normalize(SIMD3<Float>(1, -1, 0.8))
        let slantedRight = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), slanted))
        return [
            View(name: "top", caption: "seen from above: +X is right, +Y is up in the picture", right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), toward: SIMD3(0, 0, 1)),
            View(name: "front", caption: "seen from the front (from -Y): +X is right, +Z is up in the picture", right: SIMD3(1, 0, 0), up: SIMD3(0, 0, 1), toward: SIMD3(0, -1, 0)),
            View(name: "right", caption: "seen from the right (from +X): +Y is right, +Z is up in the picture", right: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1), toward: SIMD3(1, 0, 0)),
            View(name: "corner", caption: "seen from the front right, slightly above, for the overall form (do not measure in this one)", right: slantedRight, up: simd_cross(slanted, slantedRight), toward: slanted),
        ]
    }()

    /// Grey pixels, `size` × `size`, white background. `span` is how many millimetres the picture is
    /// wide and high, centred on `centre`. Surfaces facing the viewer are light, steep ones dark.
    static func render(_ mesh: Mesh, view: View, centre: SIMD3<Float>, span: Float, size: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: size * size)
        var depth = [Float](repeating: -.infinity, count: size * size)
        let scale = Float(size) / span
        func project(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let q = p - centre
            return SIMD3((simd_dot(q, view.right) * scale) + Float(size) / 2, Float(size) / 2 - simd_dot(q, view.up) * scale, simd_dot(q, view.toward))
        }
        for face in mesh.faces {
            guard face.x >= 0, face.y >= 0, face.z >= 0, face.x < mesh.vertices.count, face.y < mesh.vertices.count, face.z < mesh.vertices.count else { continue }
            let wa = mesh.vertices[face.x], wb = mesh.vertices[face.y], wc = mesh.vertices[face.z]
            let normal = simd_cross(wb - wa, wc - wa)
            let length = simd_length(normal)
            guard length > 0 else { continue }
            let grey = UInt8(40 + 190 * min(1, abs(simd_dot(normal, view.toward)) / length))
            let a = project(wa), b = project(wb), c = project(wc)
            let minX = Int(min(a.x, b.x, c.x).rounded(.down)), maxX = Int(max(a.x, b.x, c.x).rounded(.up))
            let minY = Int(min(a.y, b.y, c.y).rounded(.down)), maxY = Int(max(a.y, b.y, c.y).rounded(.up))
            if maxX < 0 || maxY < 0 || minX >= size || minY >= size { continue }
            // A triangle smaller than a pixel (most of a dense scan) is one dot.
            if maxX - minX <= 1 && maxY - minY <= 1 {
                let x = Int((a.x + b.x + c.x) / 3), y = Int((a.y + b.y + c.y) / 3), z = (a.z + b.z + c.z) / 3
                if x >= 0, y >= 0, x < size, y < size, z > depth[y * size + x] { depth[y * size + x] = z; pixels[y * size + x] = grey }
                continue
            }
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if abs(area) < 1e-6 { continue }
            for y in max(0, minY)...min(size - 1, maxY) {
                for x in max(0, minX)...min(size - 1, maxX) {
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    let w0 = ((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) / area
                    let w1 = ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) / area
                    let w2 = 1 - w0 - w1
                    if w0 < 0 || w1 < 0 || w2 < 0 { continue }
                    let z = w0 * a.z + w1 * b.z + w2 * c.z
                    if z > depth[y * size + x] { depth[y * size + x] = z; pixels[y * size + x] = grey }
                }
            }
        }
        return pixels
    }

    static func cgImage(_ pixels: [UInt8], size: Int) -> CGImage? {
        guard pixels.count == size * size, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func png(_ pixels: [UInt8], size: Int) -> Data? {
        guard let image = cgImage(pixels, size: size) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
