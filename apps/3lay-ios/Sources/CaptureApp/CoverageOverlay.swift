#if os(iOS)
import ARKit
import CaptureKit
import RealityKit
import UIKit
import simd

/// Draws ARKit's LiDAR mesh over the camera view in three colors by how well photos cover it: red needs photos,
/// orange is nearly there, green is done. Triangles are sorted into those bands from a `CoverageMap`.
///
/// Rebuilding a mesh costs, so each pass redraws only the few nearest anchors whose surface or coverage changed.
final class CoverageOverlay {
    private weak var view: ARView?
    private var roots: [UUID: AnchorEntity] = [:]
    private var built: [UUID: (vertices: Int, version: Int)] = [:]
    private var lastPass = Date.distantPast
    private let anchorsPerPass = 5
    private let materials: [UnlitMaterial] = [
        CoverageOverlay.material(red: 0.95, green: 0.2, blue: 0.2),  // needs photos
        CoverageOverlay.material(red: 1.0, green: 0.65, blue: 0.1),  // almost
        CoverageOverlay.material(red: 0.2, green: 0.85, blue: 0.35),  // done
    ]

    init(view: ARView) { self.view = view }

    private static func material(red: CGFloat, green: CGFloat, blue: CGFloat) -> UnlitMaterial {
        var material = UnlitMaterial(color: UIColor(red: red, green: green, blue: blue, alpha: 1))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.45))
        return material
    }

    /// `version` changes whenever the coverage map changed, so anchors drawn earlier know they are stale.
    func refresh(anchors: [ARMeshAnchor], cameraPosition: SIMD3<Float>, coverage: CoverageMap, version: Int) {
        guard let view, Date().timeIntervalSince(lastPass) >= 0.4 else { return }
        lastPass = Date()
        let alive = Set(anchors.map(\.identifier))
        for id in roots.keys where !alive.contains(id) {
            if let root = roots.removeValue(forKey: id) { view.scene.removeAnchor(root) }
            built[id] = nil
        }
        let stale = anchors.filter {
            let seen = built[$0.identifier]
            return seen == nil || seen!.vertices != $0.geometry.vertices.count || seen!.version != version
        }
        let nearest = stale.sorted { distance($0, cameraPosition) < distance($1, cameraPosition) }.prefix(anchorsPerPass)
        for anchor in nearest { redraw(anchor, coverage: coverage, version: version, in: view) }
    }

    func clear() {
        guard let view else { return }
        for root in roots.values { view.scene.removeAnchor(root) }
        roots.removeAll()
        built.removeAll()
    }

    private func distance(_ anchor: ARMeshAnchor, _ point: SIMD3<Float>) -> Float {
        let t = anchor.transform.columns.3
        return simd_distance(SIMD3(t.x, t.y, t.z), point)
    }

    private func redraw(_ anchor: ARMeshAnchor, coverage: CoverageMap, version: Int, in view: ARView) {
        if let old = roots.removeValue(forKey: anchor.identifier) { view.scene.removeAnchor(old) }
        built[anchor.identifier] = (anchor.geometry.vertices.count, version)
        let geometry = anchor.geometry
        let vertices = geometry.vertices, faces = geometry.faces
        guard vertices.count > 0, faces.count > 0, faces.bytesPerIndex == 4 || faces.bytesPerIndex == 2 else { return }

        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(vertices.count)
        let vertexBase = vertices.buffer.contents().advanced(by: vertices.offset)
        for i in 0..<vertices.count {
            let p = vertexBase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
            positions.append(SIMD3(p[0], p[1], p[2]))
        }

        var bands: [[UInt32]] = [[], [], []]
        let faceBase = faces.buffer.contents()
        let transform = anchor.transform
        func index(_ face: Int, _ corner: Int) -> Int {
            let at = (face * faces.indexCountPerPrimitive + corner) * faces.bytesPerIndex
            return faces.bytesPerIndex == 4
                ? Int(faceBase.load(fromByteOffset: at, as: UInt32.self))
                : Int(faceBase.load(fromByteOffset: at, as: UInt16.self))
        }
        for face in 0..<faces.count {
            let a = index(face, 0), b = index(face, 1), c = index(face, 2)
            guard a < positions.count, b < positions.count, c < positions.count else { continue }
            let local = (positions[a] + positions[b] + positions[c]) / 3
            let world = transform * SIMD4(local, 1)
            let band: Int
            switch coverage.band(at: SIMD3(world.x, world.y, world.z)) {
            case .done?: band = 2
            case .almost?: band = 1
            default: band = 0  // needs photos, or not yet in the map
            }
            bands[band].append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
        }

        let root = AnchorEntity(world: transform)
        for (i, indices) in bands.enumerated() where !indices.isEmpty {
            var descriptor = MeshDescriptor(name: "coverage\(i)")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.primitives = .triangles(indices)
            if let mesh = try? MeshResource.generate(from: [descriptor]) {
                root.addChild(ModelEntity(mesh: mesh, materials: [materials[i]]))
            }
        }
        view.scene.addAnchor(root)
        roots[anchor.identifier] = root
    }
}
#endif
