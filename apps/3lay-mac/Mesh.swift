import Foundation

struct Mesh {
    var vertices: [SIMD3<Float>]
    var faces: [SIMD3<Int>]
    var name: String
    var bounds: SIMD3<Float>

    /// Largest file `load` accepts. A full-detail photo scan is a few million triangles (50 bytes each in STL).
    static let maxFileBytes = 500_000_000
    /// USDZ (Object Capture) is in metres; the plate and STL are millimetres.
    static let metresToMillimetres: Float = 1000

    /// `unitScale` multiplies every coordinate, so a model in metres can come in as millimetres.
    /// `yUp` is for Object Capture models, which stand along Y: they are turned to stand along Z like
    /// the plate and slicers expect. (x, y, z) becomes (x, -z, y), a rotation, so nothing is mirrored.
    static func load(_ url: URL, unitScale: Float = 1, yUp: Bool = false) throws -> Mesh {
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileBytes else { throw ScanError.message("File exceeds the 500 MB import limit") }
        var mesh: Mesh
        switch url.pathExtension.lowercased() {
        case "stl": mesh = try parseSTL(data)
        case "obj": mesh = try parseOBJ(data)
        case "ply": mesh = try parsePLY(data)
        default: throw ScanError.message("Choose an STL, OBJ, or ASCII PLY surface mesh")
        }
        guard !mesh.vertices.isEmpty && !mesh.faces.isEmpty else { throw ScanError.message("No surface triangles found in this file") }
        guard mesh.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw ScanError.message("Mesh contains invalid coordinates") }
        if unitScale != 1 { mesh.vertices = mesh.vertices.map { $0 * unitScale } }
        if yUp { mesh.vertices = mesh.vertices.map { SIMD3($0.x, -$0.z, $0.y) } }
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
            if count <= 10_000_000 && data.count == 84 + count * 50 {
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

    /// What a binary PLY header says about the layout of the data that follows it.
    private struct BinaryPLYHeader {
        var vertexCount = 0
        var faceCount = 0
        /// Per vertex: byte offsets of x, y, z and the whole record's size.
        var x = 0, y = 0, z = 0, vertexStride = 0
        /// Per face, in file order: a scalar of `size` bytes, or a list with these count/index sizes.
        var faceProperties: [(isList: Bool, countSize: Int, itemSize: Int)] = []
        var dataStart = 0
    }

    private static func plyTypeSize(_ type: String) -> Int? {
        switch type {
        case "char", "uchar", "int8", "uint8": return 1
        case "short", "ushort", "int16", "uint16": return 2
        case "int", "uint", "int32", "uint32", "float", "float32": return 4
        case "double", "float64": return 8
        default: return nil
        }
    }

    /// nil when this is not a binary PLY (the ASCII reader then takes over).
    private static func binaryPLYHeader(_ data: Data) throws -> BinaryPLYHeader? {
        guard data.count > 12, data.prefix(3) == Data("ply".utf8),
              let end = data.prefix(16_384).range(of: Data("end_header\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: .newlines)
        guard let format = lines.first(where: { $0.hasPrefix("format ") }) else { return nil }
        if format.contains("binary_big_endian") { throw ScanError.message("Big-endian PLY is not supported") }
        guard format.contains("binary_little_endian") else { return nil }

        var header = BinaryPLYHeader()
        header.dataStart = end.upperBound
        var element = ""
        var xType = "", yType = "", zType = ""
        var sawVertex = false, sawFace = false
        for line in lines {
            let p = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if p.count >= 3, p[0] == "element" {
                element = p[1]
                let count = Int(p[2]) ?? -1
                guard (0...10_000_000).contains(count) else { throw ScanError.message("PLY is too large") }
                switch element {
                case "vertex":
                    header.vertexCount = count
                    sawVertex = true
                case "face":
                    guard sawVertex else { throw ScanError.message("This PLY lists faces before vertices") }
                    header.faceCount = count
                    sawFace = true
                default:
                    // Another element before the faces would shift where they start.
                    if !sawFace { throw ScanError.message("This PLY has an unsupported element: \(element)") }
                }
            } else if p.count >= 3, p[0] == "property", element == "vertex" {
                guard let size = plyTypeSize(p[1]) else { throw ScanError.message("Unsupported PLY property type: \(p[1])") }
                switch p[2] {
                case "x": header.x = header.vertexStride; xType = p[1]
                case "y": header.y = header.vertexStride; yType = p[1]
                case "z": header.z = header.vertexStride; zType = p[1]
                default: break
                }
                header.vertexStride += size
            } else if p.count >= 3, p[0] == "property", element == "face" {
                if p[1] == "list" {
                    guard p.count >= 5, let countSize = plyTypeSize(p[2]), let itemSize = plyTypeSize(p[3]), [1, 2, 4].contains(itemSize), [1, 2, 4].contains(countSize)
                    else { throw ScanError.message("Unsupported PLY face list") }
                    header.faceProperties.append((true, countSize, itemSize))
                } else {
                    guard let size = plyTypeSize(p[1]) else { throw ScanError.message("Unsupported PLY property type: \(p[1])") }
                    header.faceProperties.append((false, 0, size))
                }
            }
        }
        guard [xType, yType, zType].allSatisfy({ $0 == "float" || $0 == "float32" }) else {
            throw ScanError.message("This PLY needs float x, y and z vertex coordinates")
        }
        guard header.vertexCount > 0, header.faceCount > 0, header.faceProperties.contains(where: { $0.isList }) else {
            throw ScanError.message("No surface triangles found in this file")
        }
        return header
    }

    private static func parseBinaryPLY(_ data: Data, _ header: BinaryPLYHeader) throws -> Mesh {
        var mesh = empty()
        mesh.vertices.reserveCapacity(header.vertexCount)
        let verticesEnd = header.dataStart + header.vertexCount * header.vertexStride
        guard header.vertexStride >= 12, verticesEnd <= data.count else { throw ScanError.message("PLY ended before all vertices") }
        for i in 0..<header.vertexCount {
            let at = header.dataStart + i * header.vertexStride
            mesh.vertices.append(SIMD3(data.readLE(Float.self, at: at + header.x), data.readLE(Float.self, at: at + header.y), data.readLE(Float.self, at: at + header.z)))
        }
        var cursor = verticesEnd
        mesh.faces.reserveCapacity(header.faceCount)
        for _ in 0..<header.faceCount {
            for property in header.faceProperties {
                if !property.isList {
                    cursor += property.itemSize
                    continue
                }
                guard cursor + property.countSize <= data.count else { throw ScanError.message("PLY ended before all faces") }
                let count = property.countSize == 1 ? Int(data.readLE(UInt8.self, at: cursor))
                    : property.countSize == 2 ? Int(data.readLE(UInt16.self, at: cursor)) : Int(data.readLE(UInt32.self, at: cursor))
                cursor += property.countSize
                guard count <= 64, cursor + count * property.itemSize <= data.count else { throw ScanError.message("PLY ended before all faces") }
                var ids: [Int] = []
                ids.reserveCapacity(count)
                for k in 0..<count {
                    let at = cursor + k * property.itemSize
                    let id = property.itemSize == 1 ? Int(data.readLE(UInt8.self, at: at))
                        : property.itemSize == 2 ? Int(data.readLE(UInt16.self, at: at)) : Int(data.readLE(UInt32.self, at: at))
                    guard id < mesh.vertices.count else { throw ScanError.message("PLY face references a missing vertex") }
                    ids.append(id)
                }
                cursor += count * property.itemSize
                if count >= 3 { for i in 1..<(count - 1) { mesh.faces.append(SIMD3(ids[0], ids[i], ids[i + 1])) } }
            }
        }
        return mesh
    }

    private static func parsePLY(_ data: Data) throws -> Mesh {
        if let header = try binaryPLYHeader(data) { return try parseBinaryPLY(data, header) }
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
        guard ascii, let start = headerEnd else { throw ScanError.message("Export the PLY as ASCII or binary little-endian with surface faces") }
        guard (0...10_000_000).contains(vertexCount), (0...10_000_000).contains(faceCount) else { throw ScanError.message("PLY is too large") }
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
