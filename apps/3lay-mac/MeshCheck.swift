import Foundation

@main struct MeshCheck {
    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".build/check", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let obj = directory.appending(path: "triangle.obj")
        try "v 0 0 0\nv 20 0 0\nv 0 10 0\nf 1 2 3\n".write(to: obj, atomically: true, encoding: .utf8)
        let mesh = try Mesh.load(obj)
        guard mesh.faces.count == 1, mesh.bounds.x == 20, mesh.bounds.y == 10 else { throw ScanError.message("OBJ import check failed") }

        let exported = directory.appending(path: "placed.stl")
        try mesh.saveSTL(exported, scale: 2, angle: 90)
        let roundTrip = try Mesh.load(exported)
        guard roundTrip.faces.count == 1, abs(roundTrip.bounds.x - 20) < 0.01, abs(roundTrip.bounds.y - 40) < 0.01 else { throw ScanError.message("STL export check failed") }

        let ply = directory.appending(path: "triangle.ply")
        try "ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0\n1 0 0\n0 1 0\n3 0 1 2\n".write(to: ply, atomically: true, encoding: .utf8)
        guard try Mesh.load(ply).faces.count == 1 else { throw ScanError.message("PLY import check failed") }
        // Binary little-endian PLY as the phone writes it (float xyz, face list uchar int), plus an
        // extra per-vertex float and a per-face class byte like other LiDAR exporters add.
        let binary = directory.appending(path: "binary.ply")
        var bytes = Data("ply\nformat binary_little_endian 1.0\nelement vertex 4\nproperty float x\nproperty float y\nproperty float z\nproperty float coverage\nelement face 2\nproperty list uchar int vertex_indices\nproperty uchar class\nend_header\n".utf8)
        func put(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) } }
        for v: [Float] in [[0, 0, 0, 1], [0.3, 0, 0, 1], [0.3, 0.2, 0, 1], [0, 0.2, 0.1, 1]] { for c in v { put(c.bitPattern) } }
        for face: [UInt32] in [[0, 1, 2], [0, 2, 3]] { bytes.append(3); for i in face { put(i) }; bytes.append(2) }
        try bytes.write(to: binary)
        let fromBinary = try Mesh.load(binary, unitScale: Mesh.metresToMillimetres)
        guard fromBinary.faces.count == 2, fromBinary.vertices.count == 4, abs(fromBinary.bounds.x - 300) < 0.01, abs(fromBinary.bounds.y - 200) < 0.01
        else { throw ScanError.message("Binary PLY import check failed") }
        // A truncated file must be refused, not read past its end.
        try bytes.dropLast(8).write(to: directory.appending(path: "cut.ply"))
        var acceptedCut = true
        do { _ = try Mesh.load(directory.appending(path: "cut.ply")) } catch { acceptedCut = false }
        guard !acceptedCut else { throw ScanError.message("Truncated binary PLY was accepted") }

        // A USDZ model is in metres: 0.2 m must come in as 200 mm.
        let metres = directory.appending(path: "metres.obj")
        try "v 0 0 0\nv 0.2 0 0\nv 0 0.1 0\nf 1 2 3\n".write(to: metres, atomically: true, encoding: .utf8)
        let scaled = try Mesh.load(metres, unitScale: Mesh.metresToMillimetres)
        guard abs(scaled.bounds.x - 200) < 0.01, abs(scaled.bounds.y - 100) < 0.01 else { throw ScanError.message("Metres to millimetres check failed") }
        // 3MF: a real zip (checked with the system unzip) holding a millimetre model with the right counts.
        let threeMF = directory.appending(path: "placed.3mf")
        try mesh.save3MF(threeMF, scale: 2, angle: 90)
        let listing = try run("/usr/bin/unzip", ["-tq", threeMF.path])
        guard listing.status == 0 else { throw ScanError.message("3MF is not a valid zip: \(listing.output)") }
        let xml = try run("/usr/bin/unzip", ["-p", threeMF.path, "3D/3dmodel.model"]).output
        guard xml.contains(#"unit="millimeter""#), xml.components(separatedBy: "<vertex ").count == 4,
              xml.components(separatedBy: "<triangle ").count == 2, xml.contains(#"<item objectid="1"/>"#)
        else { throw ScanError.message("3MF model check failed") }
        let placed = mesh.placedVertices(scale: 2, angle: 90)
        let ys = placed.map(\.y)
        guard abs((ys.max()! - ys.min()!) - 40) < 0.01 else { throw ScanError.message("3MF placement check failed") }
        // A closed box as STL lists it (3 private vertices per triangle) must come out welded: 8 vertices,
        // and every edge shared by exactly two triangles.
        let corner: [SIMD3<Float>] = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0], [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]]
        let boxFaces: [[Int]] = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4],
                                 [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]]
        let soup = boxFaces.flatMap { $0.map { corner[$0] } }
        let (weldedVertices, weldedFaces) = try ThreeMF.welded(vertices: soup, faces: (0..<12).map { SIMD3($0 * 3, $0 * 3 + 1, $0 * 3 + 2) })
        guard weldedVertices.count == 8, weldedFaces.count == 12 else { throw ScanError.message("3MF weld check failed") }
        var edgeUses: [[Int]: Int] = [:]
        for f in weldedFaces { for (a, b) in [(f.x, f.y), (f.y, f.z), (f.z, f.x)] { edgeUses[[min(a, b), max(a, b)], default: 0] += 1 } }
        guard edgeUses.count == 18, edgeUses.values.allSatisfy({ $0 == 2 }) else { throw ScanError.message("3MF edges are not shared") }
        // -0.0 and 0.0 are one vertex.
        let negativeZero = try ThreeMF.welded(vertices: [[0, 0, 0], [-0.0, 0, 0], [1, 0, 0], [0, 1, 0]], faces: [SIMD3(1, 2, 3)])
        guard negativeZero.0.count == 3 else { throw ScanError.message("3MF -0.0 weld check failed") }
        // Big enough to take the deflate path; unzip -t verifies the CRC of what we wrote.
        let grid = (0..<2000).map { SIMD3<Float>(Float($0 % 50), Float($0 / 50), 0) }
        let strips = (0..<1990).map { SIMD3<Int>($0, $0 + 1, $0 + 10) }
        let big = directory.appending(path: "big.3mf")
        try ThreeMF.data(title: "A & B <grid>", vertices: grid, faces: strips).write(to: big)
        guard try run("/usr/bin/unzip", ["-tq", big.path]).status == 0 else { throw ScanError.message("Deflated 3MF check failed") }
        guard try run("/usr/bin/unzip", ["-p", big.path, "3D/3dmodel.model"]).output.contains("A &amp; B &lt;grid&gt;") else {
            throw ScanError.message("3MF title escaping check failed")
        }
        print("Mesh import, STL export and 3MF export passed")
    }
}
