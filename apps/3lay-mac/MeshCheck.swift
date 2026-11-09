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
        print("Mesh import and STL export passed")
    }
}
