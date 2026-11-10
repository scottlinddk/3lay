import Foundation

@main struct MeshCheck {
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
        print("Mesh import and STL export passed")
    }
}
