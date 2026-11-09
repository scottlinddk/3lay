import Foundation

struct Mesh {
    var vertices: [SIMD3<Float>]
    var faces: [SIMD3<Int>]
    var name: String
    var bounds: SIMD3<Float>

    static func load(_ url: URL) throws -> Mesh {
        let data = try Data(contentsOf: url)
        guard data.count <= 100_000_000 else { throw ScanError.message("File exceeds the 100 MB import limit") }
        var mesh: Mesh
        switch url.pathExtension.lowercased() {
        case "stl": mesh = try parseSTL(data)
        case "obj": mesh = try parseOBJ(data)
        case "ply": mesh = try parsePLY(data)
        default: throw ScanError.message("Choose an STL, OBJ, or ASCII PLY surface mesh")
        }
        guard !mesh.vertices.isEmpty && !mesh.faces.isEmpty else { throw ScanError.message("No surface triangles found in this file") }
        guard mesh.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw ScanError.message("Mesh contains invalid coordinates") }
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        for v in mesh.vertices {
            lo = SIMD3(Swift.min(lo.x, v.x), Swift.min(lo.y, v.y), Swift.min(lo.z, v.z))
            hi = SIMD3(Swift.max(hi.x, v.x), Swift.max(hi.y, v.y), Swift.max(hi.z, v.z))
        }
        mesh.bounds = hi - lo
        let center = SIMD3<Float>((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z)
        mesh.vertices = mesh.vertices.map { $0 - center }
        mesh.name = url.lastPathComponent
        return mesh
    }

    func saveSTL(_ url: URL, scale: Float, angle: Float) throws {
        guard faces.count <= Int(UInt32.max) else { throw ScanError.message("Too many triangles for STL") }
        var out = Data(repeating: 0, count: 80)
        let tag = Data("3lay Mac".utf8)
        out.replaceSubrange(0..<tag.count, with: tag)
        out.appendLE(UInt32(faces.count))
        let radians = angle * .pi / 180
        let c = cos(radians), s = sin(radians)
        for face in faces {
            out.append(Data(repeating: 0, count: 12))
            for index in [face.x, face.y, face.z] {
                guard vertices.indices.contains(index) else { throw ScanError.message("Mesh face references a missing vertex") }
                let v = vertices[index] * scale
                out.appendLE(v.x * c - v.y * s)
                out.appendLE(v.x * s + v.y * c)
                out.appendLE(v.z)
            }
            out.appendLE(UInt16(0))
        }
        try out.write(to: url, options: .atomic)
    }

    private static func empty() -> Mesh { Mesh(vertices: [], faces: [], name: "", bounds: .zero) }

    private static func parseSTL(_ data: Data) throws -> Mesh {
        var mesh = empty()
        if data.count >= 84 {
            let count = Int(data.readLE(UInt32.self, at: 80))
            if count <= 2_000_000 && data.count == 84 + count * 50 {
                mesh.vertices.reserveCapacity(count * 3)
                mesh.faces.reserveCapacity(count)
                for t in 0..<count {
                    let base = 84 + t * 50 + 12
                    let n = mesh.vertices.count
                    for j in 0..<3 {
                        let at = base + j * 12
                        mesh.vertices.append(SIMD3(data.readLE(Float.self, at: at), data.readLE(Float.self, at: at + 4), data.readLE(Float.self, at: at + 8)))
                    }
                    mesh.faces.append(SIMD3(n, n + 1, n + 2))
                }
                return mesh
            }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ScanError.message("STL data is invalid") }
        var tri: [SIMD3<Float>] = []
        for line in text.components(separatedBy: .newlines) {
            let p = line.split(whereSeparator: \.isWhitespace)
            if p.first == "vertex", p.count >= 4 {
                guard let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) else { throw ScanError.message("Invalid STL vertex") }
                tri.append(SIMD3(x, y, z))
                if tri.count == 3 {
                    let n = mesh.vertices.count
                    mesh.vertices.append(contentsOf: tri)
                    mesh.faces.append(SIMD3(n, n + 1, n + 2))
                    tri.removeAll(keepingCapacity: true)
                }
            }
        }
        return mesh
    }

    private static func parseOBJ(_ data: Data) throws -> Mesh {
        guard let text = String(data: data, encoding: .utf8) else { throw ScanError.message("OBJ is not UTF-8") }
        var mesh = empty()
        for line in text.components(separatedBy: .newlines) {
            let p = line.split(whereSeparator: \.isWhitespace)
            guard let first = p.first else { continue }
            if first == "v" {
                guard p.count >= 4, let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) else { throw ScanError.message("Invalid OBJ vertex") }
                mesh.vertices.append(SIMD3(x, y, z))
            } else if first == "f" {
                var ids: [Int] = []
                for token in p.dropFirst() {
                    guard let raw = Int(token.split(separator: "/", omittingEmptySubsequences: false).first ?? "") else { throw ScanError.message("Invalid OBJ face") }
                    let index = raw > 0 ? raw - 1 : mesh.vertices.count + raw
                    guard mesh.vertices.indices.contains(index) else { throw ScanError.message("OBJ face references a missing vertex") }
                    ids.append(index)
                }
                if ids.count >= 3 { for i in 1..<(ids.count - 1) { mesh.faces.append(SIMD3(ids[0], ids[i], ids[i + 1])) } }
            }
        }
        return mesh
    }

    private static func parsePLY(_ data: Data) throws -> Mesh {
        guard let text = String(data: data, encoding: .utf8) else { throw ScanError.message("Only ASCII PLY is supported") }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "ply" else { throw ScanError.message("Invalid PLY header") }
        var vertexCount = 0, faceCount = 0, ascii = false, headerEnd: Int?
        for (index, line) in lines.enumerated() {
            let p = line.split(whereSeparator: \.isWhitespace)
            if p.count >= 3 && p[0] == "format" { ascii = p[1] == "ascii" }
            if p.count >= 3 && p[0] == "element" && p[1] == "vertex" { vertexCount = Int(p[2]) ?? -1 }
            if p.count >= 3 && p[0] == "element" && p[1] == "face" { faceCount = Int(p[2]) ?? -1 }
            if line == "end_header" { headerEnd = index + 1; break }
        }
        guard ascii, let start = headerEnd else { throw ScanError.message("Export the PLY as ASCII with surface faces") }
        guard (0...5_000_000).contains(vertexCount), (0...5_000_000).contains(faceCount) else { throw ScanError.message("PLY is too large") }
        guard lines.count >= start + vertexCount + faceCount else { throw ScanError.message("PLY ended before all geometry") }
        var mesh = empty()
        for index in start..<(start + vertexCount) {
            let p = lines[index].split(whereSeparator: \.isWhitespace)
            guard p.count >= 3, let x = Float(p[0]), let y = Float(p[1]), let z = Float(p[2]) else { throw ScanError.message("Invalid PLY vertex") }
            mesh.vertices.append(SIMD3(x, y, z))
        }
        for index in (start + vertexCount)..<(start + vertexCount + faceCount) {
            let p = lines[index].split(whereSeparator: \.isWhitespace)
            guard let first = p.first, let count = Int(first), count >= 0, p.count > count else { throw ScanError.message("Invalid PLY face") }
            if count < 3 { continue }
            let ids = try p.dropFirst().prefix(count).map { token -> Int in
                guard let id = Int(token), mesh.vertices.indices.contains(id) else { throw ScanError.message("PLY face references a missing vertex") }
                return id
            }
            for i in 1..<(ids.count - 1) { mesh.faces.append(SIMD3(ids[0], ids[i], ids[i + 1])) }
        }
        return mesh
    }
}

enum ScanError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

private extension Data {
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        let value = withUnsafeBytes { raw in raw.loadUnaligned(fromByteOffset: offset, as: T.self) }
        return T(littleEndian: value)
    }
    func readLE(_ type: Float.Type, at offset: Int) -> Float { Float(bitPattern: readLE(UInt32.self, at: offset)) }
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: Float) { appendLE(value.bitPattern) }
}
