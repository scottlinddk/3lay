import Compression
import Foundation

/// Writes a surface mesh as a 3MF package: a zip holding `3D/3dmodel.model`.
///
/// Unlike STL, 3MF states its unit (`millimeter` here), so Bambu Studio and other slicers open the
/// model at the right size without asking. It carries geometry only: no printer, filament or
/// sliced toolpaths. Slicing still happens in the slicer.
enum ThreeMF {
    private static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
        """
    private static let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
        """

    /// `vertices` are in millimetres. Triangles wind counter-clockwise seen from outside, as in STL.
    static func data(title: String, vertices: [SIMD3<Float>], faces: [SIMD3<Int>]) throws -> Data {
        guard !vertices.isEmpty, !faces.isEmpty else { throw ScanError.message("Nothing to export") }
        var model = #"<?xml version="1.0" encoding="UTF-8"?>"#
        model.reserveCapacity(vertices.count * 48 + faces.count * 40 + 512)
        model += #"<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">"#
        model += #"<metadata name="Title">\#(escape(title))</metadata><metadata name="Application">3lay Mac</metadata>"#
        model += #"<resources><object id="1" type="model"><mesh><vertices>"#
        for v in vertices { model += "<vertex x=\"\(v.x)\" y=\"\(v.y)\" z=\"\(v.z)\"/>" }
        model += "</vertices><triangles>"
        for f in faces {
            guard vertices.indices.contains(f.x), vertices.indices.contains(f.y), vertices.indices.contains(f.z) else {
                throw ScanError.message("Mesh face references a missing vertex")
            }
            model += "<triangle v1=\"\(f.x)\" v2=\"\(f.y)\" v3=\"\(f.z)\"/>"
        }
        model += #"</triangles></mesh></object></resources><build><item objectid="1"/></build></model>"#
        return try Zip.archive([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("3D/3dmodel.model", Data(model.utf8)),
        ])
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

extension Mesh {
    /// Same placement as `saveSTL`: scale, then turn around the upright (z) axis.
    func placedVertices(scale: Float, angle: Float) -> [SIMD3<Float>] {
        let radians = angle * .pi / 180
        let c = cos(radians), s = sin(radians)
        return vertices.map { raw in
            let v = raw * scale
            return SIMD3(v.x * c - v.y * s, v.x * s + v.y * c, v.z)
        }
    }

    func save3MF(_ url: URL, scale: Float, angle: Float) throws {
        let title = (name as NSString).deletingPathExtension
        let data = try ThreeMF.data(title: title.isEmpty ? "3lay scan" : title,
                                    vertices: placedVertices(scale: scale, angle: angle), faces: faces)
        try data.write(to: url, options: .atomic)
    }
}

/// Minimal zip writer: one deflated (or stored) entry after another, no zip64. A 3MF is far below 4 GB.
enum Zip {
    static func archive(_ entries: [(name: String, data: Data)]) throws -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let (method, body) = deflate(entry.data).map { (UInt16(8), $0) } ?? (UInt16(0), entry.data)
            guard out.count < Int(UInt32.max) - body.count, entries.count < Int(UInt16.max) else {
                throw ScanError.message("Model is too large for a 3MF file")
            }
            let offset = UInt32(out.count)
            // Local file header.
            out.appendLE32(0x0403_4B50); out.appendLE16(20); out.appendLE16(0x0800)  // 0x0800: names are UTF-8
            out.appendLE16(method); out.appendLE16(0); out.appendLE16(0x21)  // time 00:00, date 1980-01-01
            out.appendLE32(crc); out.appendLE32(UInt32(body.count)); out.appendLE32(UInt32(entry.data.count))
            out.appendLE16(UInt16(name.count)); out.appendLE16(0)
            out.append(name); out.append(body)
            // Central directory record.
            central.appendLE32(0x0201_4B50); central.appendLE16(20); central.appendLE16(20); central.appendLE16(0x0800)
            central.appendLE16(method); central.appendLE16(0); central.appendLE16(0x21)
            central.appendLE32(crc); central.appendLE32(UInt32(body.count)); central.appendLE32(UInt32(entry.data.count))
            central.appendLE16(UInt16(name.count)); central.appendLE16(0); central.appendLE16(0)
            central.appendLE16(0); central.appendLE16(0); central.appendLE32(0); central.appendLE32(offset)
            central.append(name)
        }
        guard out.count + central.count < Int(UInt32.max) else { throw ScanError.message("Model is too large for a 3MF file") }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.appendLE32(0x0605_4B50); out.appendLE16(0); out.appendLE16(0)
        out.appendLE16(UInt16(entries.count)); out.appendLE16(UInt16(entries.count))
        out.appendLE32(UInt32(central.count)); out.appendLE32(centralOffset); out.appendLE16(0)
        return out
    }

    /// Raw DEFLATE (what zip method 8 stores). Apple's `COMPRESSION_ZLIB` emits exactly this, without a
    /// zlib header. nil when it does not shrink the data, so the caller stores it instead.
    private static func deflate(_ data: Data) -> Data? {
        guard data.count > 64 else { return nil }
        let capacity = data.count  // output must be smaller than the input to be worth keeping
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&buffer, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return written > 0 && written < data.count ? Data(buffer.prefix(written)) : nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func appendLE32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
