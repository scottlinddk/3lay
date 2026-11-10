import Foundation
import simd

/// Checks the clean-part engine without calling Claude: shape JSON, distances, the closed mesh,
/// the fit measurement, the pictures and the OpenSCAD export.
@main struct RebuildCheck {
    static func fail(_ message: String) -> Error { NSError(domain: "RebuildCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

    static func shape(_ json: String) throws -> SolidShape { try SolidShape(SolidDocument.parse(reply: json).shape) }

    static func main() throws {
        // A 40 × 30 × 20 block standing on Z = 0 with a 10 mm hole down through it, wrapped in the
        // kind of words and code fence a reply can come with.
        let block = try shape("""
            Here is the model:
            ```json
            {"notes": "block with a hole", "shape": {"op": "subtract", "children": [
              {"op": "box", "size": [40, 30, 20], "center": [0, 0, 10]},
              {"op": "cylinder", "radius": 5, "height": 30, "center": [0, 0, 10]}]}}
            ```
            """)
        func near(_ value: Float, _ expected: Float, _ what: String) throws {
            guard abs(value - expected) < 0.01 else { throw fail("\(what): expected \(expected), got \(value)") }
        }
        try near(block.distance(SIMD3(0, 0, 10)), 5, "in the hole")
        try near(block.distance(SIMD3(15, 0, 10)), -5, "in the wall")
        try near(block.distance(SIMD3(30, 0, 10)), 10, "outside")

        // Rotation is X first: a cylinder turned 90° about X lies along Y.
        let lying = try shape(#"{"shape": {"op": "cylinder", "radius": 2, "height": 20, "rotate": [90, 0, 0]}}"#)
        guard lying.distance(SIMD3(0, 9, 0)) < 0, lying.distance(SIMD3(0, 0, 9)) > 0 else { throw fail("rotate did not lay the cylinder along Y") }
        // X then Z: a box long in X, turned 90° about Z, is long in Y.
        let turned = try shape(#"{"shape": {"op": "box", "size": [20, 2, 2], "rotate": [0, 0, 90]}}"#)
        guard turned.distance(SIMD3(0, 9, 0)) < 0, turned.distance(SIMD3(9, 0, 0)) > 0 else { throw fail("rotate about Z is wrong") }
        // An L outline: inside the foot, outside the notch.
        let bracket = try shape(#"{"shape": {"op": "extrude", "points": [[0,0],[20,0],[20,5],[5,5],[5,20],[0,20]], "height": 10}}"#)
        guard bracket.distance(SIMD3(15, 2, 0)) < 0, bracket.distance(SIMD3(15, 15, 0)) > 0, bracket.distance(SIMD3(2, 15, 6)) > 0 else { throw fail("extrude is wrong") }
        // A cone is wide at the bottom.
        let cone = try shape(#"{"shape": {"op": "cone", "radius1": 10, "radius2": 5, "height": 10}}"#)
        guard cone.distance(SIMD3(7, 0, -4.5)) < 0, cone.distance(SIMD3(7, 0, 4.5)) > 0 else { throw fail("cone is upside down") }

        for bad in [#"{"shape": {"op": "box", "size": [1, -1, 1]}}"#, #"{"shape": {"op": "blob"}}"#, #"{"shape": {"op": "union", "children": []}}"#, "no json here"] {
            var accepted = true
            do { _ = try shape(bad) } catch { accepted = false }
            guard !accepted else { throw fail("accepted a bad shape: \(bad)") }
        }

        // The mesh is closed, faces outwards and has the right volume.
        let lo = SIMD3<Float>(-25, -20, -3), hi = SIMD3<Float>(25, 20, 23)
        let mesh = SolidMesher.mesh(block, lo: lo, hi: hi, cells: 100, name: "block")
        let expected = 40 * 30 * 20 - Float.pi * 25 * 20
        let volume = SolidMesher.volume(mesh)
        guard abs(volume - expected) / expected < 0.03 else { throw fail("volume \(volume), expected about \(expected)") }
        var edges: [SIMD2<Int>: Int] = [:]
        for face in mesh.faces {
            for (a, b) in [(face.x, face.y), (face.y, face.z), (face.z, face.x)] { edges[SIMD2(min(a, b), max(a, b)), default: 0] += 1 }
        }
        guard edges.values.allSatisfy({ $0 == 2 }) else { throw fail("the mesh has open or doubled edges") }
        // A shape larger than the box it is meshed in is still closed.
        let clipped = SolidMesher.mesh(try shape(#"{"shape": {"op": "sphere", "radius": 50}}"#), lo: lo, hi: hi, cells: 40, name: "clipped")
        guard SolidMesher.volume(clipped) > 0.9 * 50 * 40 * 26 else { throw fail("a clipped shape was not closed") }

        // Fit: the same part at another resolution is close; a block without the hole is caught there.
        let scan = SolidMesher.mesh(block, lo: lo, hi: hi, cells: 70, name: "scan")
        let good = ShapeFit.measure(shape: block, scan: scan, model: mesh)
        guard good.meanScanToModel < 0.15, good.meanModelToScan < 0.6 else { throw fail("a matching part measured as far: \(good.meanScanToModel), \(good.meanModelToScan)") }
        let solid = try shape(#"{"shape": {"op": "box", "size": [40, 30, 20], "center": [0, 0, 10]}}"#)
        let miss = ShapeFit.measure(shape: solid, scan: scan, model: SolidMesher.mesh(solid, lo: lo, hi: hi, cells: 70, name: "solid"))
        guard miss.score > good.score * 2, let worst = miss.worst.first, worst.signed < -3, simd_length(SIMD2(worst.point.x, worst.point.y)) < 7 else {
            throw fail("a missing hole was not reported: \(miss.worst)")
        }
        guard miss.bias < 0 else { throw fail("a missing hole should read as too much material") }

        // Pictures: the top view shows the hole as background in the middle of the part.
        let size = 128
        let top = MeshRender.render(mesh, view: MeshRender.views[0], centre: (lo + hi) / 2, span: 60, size: size)
        guard top[size / 2 * size + size / 2] == 255, top[size / 2 * size + size / 2 + 30] < 255, top[0] == 255 else { throw fail("the top view is wrong") }
        guard let png = MeshRender.png(top, size: size), png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) else { throw fail("no PNG") }

        let scad = block.openSCAD()
        guard scad.contains("difference()"), scad.contains("cube([40.000, 30.000, 20.000], center = true)"), scad.contains("cylinder(h = 30.000, r = 5.000") else {
            throw fail("OpenSCAD export is wrong:\n\(scad)")
        }
        print("Clean rebuild check passed")
    }
}
