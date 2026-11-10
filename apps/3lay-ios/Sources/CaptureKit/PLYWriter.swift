import Foundation
import simd

/// Writes a triangle mesh as binary little-endian PLY: `float x y z` per vertex and
/// `list uchar int vertex_indices` per face. 3lay Mac reads exactly this (`Mesh.parsePLY`).
public enum PLYWriter {
    public enum WriteError: Error, LocalizedError {
        case empty
        case badIndex
        public var errorDescription: String? {
            switch self {
            case .empty: return "The LiDAR mesh is empty."
            case .badIndex: return "The LiDAR mesh refers to a missing vertex."
            }
        }
    }

    public static func write(vertices: [SIMD3<Float>], triangles: [SIMD3<UInt32>], to url: URL) throws {
        guard !vertices.isEmpty, !triangles.isEmpty else { throw WriteError.empty }
        let header = """
            ply
            format binary_little_endian 1.0
            element vertex \(vertices.count)
            property float x
            property float y
            property float z
            element face \(triangles.count)
            property list uchar int vertex_indices
            end_header

            """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + vertices.count * 12 + triangles.count * 13)
        for v in vertices {
            for component in [v.x, v.y, v.z] { append(component.bitPattern, to: &data) }
        }
        for t in triangles {
            guard Int(t.x) < vertices.count, Int(t.y) < vertices.count, Int(t.z) < vertices.count else { throw WriteError.badIndex }
            data.append(3)
            for index in [t.x, t.y, t.z] { append(index, to: &data) }
        }
        try data.write(to: url, options: .atomic)
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
