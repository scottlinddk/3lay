import Foundation
import simd

/// Writes a triangle mesh as binary little-endian PLY: `float x y z` per vertex and
/// `list uchar int vertex_indices` per face. 3lay Mac reads exactly this (`Mesh.parsePLY`).
///
/// Output is streamed in bounded buffers to a temporary file next to the destination and moved into
/// place when complete, so a failure or crash never leaves a half-written `scan.ply` behind.
public enum PLYWriter {
    public enum WriteError: Error, LocalizedError {
        case empty
        case badIndex
        case inconsistentChunk
        public var errorDescription: String? {
            switch self {
            case .empty: return "The LiDAR mesh is empty."
            case .badIndex: return "The LiDAR mesh refers to a missing vertex."
            case .inconsistentChunk: return "The LiDAR mesh data was cut short."
            }
        }
    }

    /// Bytes held in memory before they are flushed to disk.
    static let bufferLimit = 1 << 20

    public struct Summary: Equatable {
        public let vertexCount: Int
        public let triangleCount: Int
    }

    public static func write(vertices: [SIMD3<Float>], triangles: [SIMD3<UInt32>], to url: URL) throws {
        guard !vertices.isEmpty, !triangles.isEmpty else { throw WriteError.empty }
        try stream(to: url, vertexCount: vertices.count, triangleCount: triangles.count) { out in
            for v in vertices { out.append(v.x); out.append(v.y); out.append(v.z) }
            try out.flushIfNeeded()
            for t in triangles {
                guard Int(t.x) < vertices.count, Int(t.y) < vertices.count, Int(t.z) < vertices.count else {
                    throw WriteError.badIndex
                }
                out.append(UInt8(3)); out.append(t.x); out.append(t.y); out.append(t.z)
                try out.flushIfNeeded()
            }
        }
    }

    /// Writes all chunks as one mesh in meters, Z up. ARKit's world is Y up; the file is Z up (what the
    /// plate and slicers expect): (x, y, z) becomes (x, -z, y), a plain rotation, so winding is kept.
    /// Nothing larger than the output buffer is held besides the (already copied) chunks.
    @discardableResult
    public static func write(chunks: [MeshChunk], to url: URL) throws -> Summary {
        let usable = chunks.filter { $0.vertexCount > 0 && $0.faceCount > 0 }
        guard !usable.isEmpty else { throw WriteError.empty }
        guard usable.allSatisfy(\.isConsistent) else { throw WriteError.inconsistentChunk }
        let vertexTotal = usable.reduce(0) { $0 + $1.vertexCount }
        let faceTotal = usable.reduce(0) { $0 + $1.faceCount }
        try stream(to: url, vertexCount: vertexTotal, triangleCount: faceTotal) { out in
            for chunk in usable {
                try chunk.vertexData.withUnsafeBytes { raw in
                    for i in 0..<chunk.vertexCount {
                        let local = SIMD4<Float>(
                            raw.loadUnaligned(fromByteOffset: i * 12, as: Float.self),
                            raw.loadUnaligned(fromByteOffset: i * 12 + 4, as: Float.self),
                            raw.loadUnaligned(fromByteOffset: i * 12 + 8, as: Float.self), 1)
                        let world = chunk.transform * local
                        out.append(world.x); out.append(-world.z); out.append(world.y)
                        try out.flushIfNeeded()
                    }
                }
            }
            var base: UInt32 = 0
            for chunk in usable {
                let width = chunk.bytesPerIndex
                try chunk.faceData.withUnsafeBytes { raw in
                    func index(_ n: Int) -> UInt32 {
                        width == 2
                            ? UInt32(raw.loadUnaligned(fromByteOffset: n * 2, as: UInt16.self))
                            : raw.loadUnaligned(fromByteOffset: n * 4, as: UInt32.self)
                    }
                    for f in 0..<chunk.faceCount {
                        let a = index(f * 3), b = index(f * 3 + 1), c = index(f * 3 + 2)
                        guard Int(a) < chunk.vertexCount, Int(b) < chunk.vertexCount, Int(c) < chunk.vertexCount else {
                            throw WriteError.badIndex
                        }
                        out.append(UInt8(3)); out.append(base + a); out.append(base + b); out.append(base + c)
                        try out.flushIfNeeded()
                    }
                }
                base += UInt32(chunk.vertexCount)
            }
        }
        return Summary(vertexCount: vertexTotal, triangleCount: faceTotal)
    }

    // MARK: Streaming

    final class Sink {
        private let handle: FileHandle
        private var buffer = Data()
        init(handle: FileHandle) {
            self.handle = handle
            buffer.reserveCapacity(PLYWriter.bufferLimit + 64)
        }
        func append(_ value: Float) { append(value.bitPattern) }
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { buffer.append(contentsOf: $0) }
        }
        func append(_ value: UInt8) { buffer.append(value) }
        func append(header: String) { buffer.append(contentsOf: header.utf8) }
        func flushIfNeeded() throws {
            if buffer.count >= PLYWriter.bufferLimit { try flush() }
        }
        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    /// Moves `temporary` onto `url`, replacing what is there, in one step: readers see the old file or
    /// the new one, never a mix. (`rename(2)` also works when `url` does not exist yet.)
    private static func replace(_ url: URL, with temporary: URL) throws {
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func stream(
        to url: URL, vertexCount: Int, triangleCount: Int, body: (Sink) throws -> Void
    ) throws {
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            let sink = Sink(handle: handle)
            sink.append(header: """
                ply
                format binary_little_endian 1.0
                element vertex \(vertexCount)
                property float x
                property float y
                property float z
                element face \(triangleCount)
                property list uchar int vertex_indices
                end_header

                """)
            try body(sink)
            try sink.flush()
            try handle.synchronize()
            try replace(url, with: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }
}
