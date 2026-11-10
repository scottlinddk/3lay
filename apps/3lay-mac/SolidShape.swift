import Foundation
import simd

/// One node of a clean-part description, as JSON. This is what the AI rebuild asks Claude to write:
/// a tree of simple solids instead of a scanned triangle soup. Lengths are millimetres, angles degrees.
///
/// Solids, all centred on `center` (default 0,0,0) and then turned by `rotate`:
/// - `box`: `size` [x, y, z], optional `round` (edge radius)
/// - `cylinder`: `radius`, `height` (axis along Z)
/// - `cone`: `radius1` (bottom), `radius2` (top), `height` (axis along Z)
/// - `sphere`: `radius`
/// - `torus`: `major`, `minor` (ring in the XY plane)
/// - `extrude`: `points` [[x, y], ...] outline in XY, `height` along Z
///
/// Groups, with `children`: `union`, `intersect`, and `subtract` (the first child minus the rest).
/// A group's `center` and `rotate` move all its children together.
///
/// `rotate` is [x, y, z] applied in that order (X first), the same as OpenSCAD's `rotate([x, y, z])`.
struct SolidSpec: Codable, Equatable {
    var op: String
    var size: [Float]?
    var radius: Float?
    var radius1: Float?
    var radius2: Float?
    var height: Float?
    var major: Float?
    var minor: Float?
    var round: Float?
    var points: [[Float]]?
    var center: [Float]?
    var rotate: [Float]?
    var children: [SolidSpec]?
}

/// The whole reply: the shape and a line of notes about what was assumed.
struct SolidDocument: Codable, Equatable {
    var notes: String?
    var shape: SolidSpec

    /// Finds the JSON object in a reply that may have words or a code fence around it.
    static func parse(reply: String) throws -> SolidDocument {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            throw ScanError.message("The reply contained no JSON object.")
        }
        do {
            return try JSONDecoder().decode(SolidDocument.self, from: Data(reply[start...end].utf8))
        } catch {
            throw ScanError.message("The reply was not valid shape JSON: \(error.localizedDescription)")
        }
    }
}

/// A checked `SolidSpec` that can answer "how far is this point from the surface?" (negative inside).
/// That one question is enough to build a watertight mesh and to measure how well it matches a scan.
final class SolidShape {
    enum Kind {
        case box(half: SIMD3<Float>, round: Float)
        case cylinder(radius: Float, half: Float)
        case cone(bottom: Float, top: Float, half: Float)
        case sphere(radius: Float)
        case torus(major: Float, minor: Float)
        case extrude(points: [SIMD2<Float>], half: Float)
        case union, subtract, intersect
    }

    static let maxNodes = 300
    static let maxDepth = 24

    let kind: Kind
    let center: SIMD3<Float>
    let rotate: SIMD3<Float>
    private let toLocal: simd_float3x3
    private let turned: Bool
    let children: [SolidShape]

    convenience init(_ spec: SolidSpec) throws {
        var count = 0
        try self.init(spec, depth: 0, count: &count)
    }

    private init(_ spec: SolidSpec, depth: Int, count: inout Int) throws {
        count += 1
        guard count <= Self.maxNodes else { throw ScanError.message("The shape has more than \(Self.maxNodes) parts.") }
        guard depth <= Self.maxDepth else { throw ScanError.message("The shape is nested too deeply.") }
        center = try Self.vector(spec.center, "center")
        rotate = try Self.vector(spec.rotate, "rotate")
        turned = rotate != .zero
        toLocal = Self.rotation(rotate).transpose

        func positive(_ value: Float?, _ name: String) throws -> Float {
            guard let value, value.isFinite, value > 0 else { throw ScanError.message("\(spec.op) needs a positive \(name).") }
            return value
        }
        var kids: [SolidShape] = []
        switch spec.op {
        case "box":
            guard let size = spec.size, size.count == 3, size.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw ScanError.message("box needs size [x, y, z] with positive numbers.")
            }
            let round = spec.round ?? 0
            guard round.isFinite, round >= 0, round <= size.min()! / 2 else { throw ScanError.message("box round must be between 0 and half its smallest side.") }
            kind = .box(half: SIMD3(size[0], size[1], size[2]) / 2 - SIMD3(repeating: round), round: round)
        case "cylinder":
            kind = .cylinder(radius: try positive(spec.radius, "radius"), half: try positive(spec.height, "height") / 2)
        case "cone":
            guard let bottom = spec.radius1, let top = spec.radius2, bottom.isFinite, top.isFinite, bottom >= 0, top >= 0, bottom + top > 0 else {
                throw ScanError.message("cone needs radius1 and radius2, not negative and not both zero.")
            }
            kind = .cone(bottom: bottom, top: top, half: try positive(spec.height, "height") / 2)
        case "sphere":
            kind = .sphere(radius: try positive(spec.radius, "radius"))
        case "torus":
            let major = try positive(spec.major, "major"), minor = try positive(spec.minor, "minor")
            guard minor < major else { throw ScanError.message("torus minor must be smaller than major.") }
            kind = .torus(major: major, minor: minor)
        case "extrude":
            guard let raw = spec.points, (3...200).contains(raw.count), raw.allSatisfy({ $0.count == 2 && $0[0].isFinite && $0[1].isFinite }) else {
                throw ScanError.message("extrude needs 3 to 200 points [[x, y], ...].")
            }
            kind = .extrude(points: raw.map { SIMD2($0[0], $0[1]) }, half: try positive(spec.height, "height") / 2)
        case "union", "subtract", "intersect":
            guard let specs = spec.children, !specs.isEmpty else { throw ScanError.message("\(spec.op) needs children.") }
            kids = try specs.map { try SolidShape($0, depth: depth + 1, count: &count) }
            kind = spec.op == "union" ? .union : spec.op == "subtract" ? .subtract : .intersect
        default:
            throw ScanError.message("Unknown shape op \"\(spec.op)\".")
        }
        children = kids
    }

    private static func vector(_ values: [Float]?, _ name: String) throws -> SIMD3<Float> {
        guard let values else { return .zero }
        guard values.count == 3, values.allSatisfy(\.isFinite) else { throw ScanError.message("\(name) must be three numbers.") }
        return SIMD3(values[0], values[1], values[2])
    }

    /// Rz · Ry · Rx, degrees: turn about X first, then Y, then Z.
    private static func rotation(_ degrees: SIMD3<Float>) -> simd_float3x3 {
        let r = degrees * (.pi / 180)
        let (cx, sx, cy, sy, cz, sz) = (cos(r.x), sin(r.x), cos(r.y), sin(r.y), cos(r.z), sin(r.z))
        let x = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cx, sx), SIMD3(0, -sx, cx)))
        let y = simd_float3x3(columns: (SIMD3(cy, 0, -sy), SIMD3(0, 1, 0), SIMD3(sy, 0, cy)))
        let z = simd_float3x3(columns: (SIMD3(cz, sz, 0), SIMD3(-sz, cz, 0), SIMD3(0, 0, 1)))
        return z * y * x
    }

    /// Signed distance from `point` to the surface: negative inside, positive outside.
    /// Exact for single solids, a safe lower bound after subtract and intersect.
    func distance(_ point: SIMD3<Float>) -> Float {
        let p = turned ? toLocal * (point - center) : point - center
        switch kind {
        case .box(let half, let round):
            let d = simd_abs(p) - half
            return simd_length(simd_max(d, .zero)) + min(max(d.x, d.y, d.z), 0) - round
        case .cylinder(let radius, let half):
            return Self.capped(simd_length(SIMD2(p.x, p.y)) - radius, abs(p.z) - half)
        case .cone(let bottom, let top, let half):
            let q = SIMD2(simd_length(SIMD2(p.x, p.y)), p.z)
            let k1 = SIMD2(top, half), k2 = SIMD2(top - bottom, 2 * half)
            let ca = SIMD2(q.x - min(q.x, q.y < 0 ? bottom : top), abs(q.y) - half)
            let cb = q - k1 + k2 * simd_clamp(simd_dot(k1 - q, k2) / simd_dot(k2, k2), 0, 1)
            let sign: Float = cb.x < 0 && ca.y < 0 ? -1 : 1
            return sign * min(simd_dot(ca, ca), simd_dot(cb, cb)).squareRoot()
        case .sphere(let radius):
            return simd_length(p) - radius
        case .torus(let major, let minor):
            return simd_length(SIMD2(simd_length(SIMD2(p.x, p.y)) - major, p.z)) - minor
        case .extrude(let points, let half):
            return Self.capped(Self.polygon(SIMD2(p.x, p.y), points), abs(p.z) - half)
        case .union:
            var best = Float.infinity
            for child in children { best = min(best, child.distance(p)) }
            return best
        case .intersect:
            var best = -Float.infinity
            for child in children { best = max(best, child.distance(p)) }
            return best
        case .subtract:
            var best = children[0].distance(p)
            for child in children.dropFirst() { best = max(best, -child.distance(p)) }
            return best
        }
    }

    /// Combines a 2D outline distance with a distance past the end caps.
    private static func capped(_ side: Float, _ cap: Float) -> Float {
        min(max(side, cap), 0) + simd_length(SIMD2(max(side, 0), max(cap, 0)))
    }

    /// Signed distance to a closed outline (negative inside), for any simple polygon.
    private static func polygon(_ p: SIMD2<Float>, _ v: [SIMD2<Float>]) -> Float {
        var d = simd_dot(p - v[0], p - v[0])
        var sign: Float = 1
        var j = v.count - 1
        for i in 0..<v.count {
            let e = v[j] - v[i], w = p - v[i]
            let length2 = simd_dot(e, e)
            let b = w - e * (length2 > 0 ? simd_clamp(simd_dot(w, e) / length2, 0, 1) : 0)
            d = min(d, simd_dot(b, b))
            let above = p.y >= v[i].y, below = p.y < v[j].y, left = e.x * w.y > e.y * w.x
            if (above && below && left) || (!above && !below && !left) { sign = -sign }
            j = i
        }
        return sign * d.squareRoot()
    }

    // MARK: OpenSCAD

    /// The same shape as OpenSCAD source, so the part can be edited by hand afterwards.
    func openSCAD() -> String { "// Rebuilt from a scan by 3lay Mac. Millimetres.\n$fn = 96;\n\n" + scad(indent: 0) }

    private func scad(indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        func n(_ value: Float) -> String { String(format: "%.3f", Double(value)) }
        func v(_ value: SIMD3<Float>) -> String { "[\(n(value.x)), \(n(value.y)), \(n(value.z))]" }
        var placement = ""
        if center != .zero { placement += "translate(\(v(center))) " }
        if turned { placement += "rotate(\(v(rotate))) " }
        func group(_ name: String) -> String {
            "\(pad)\(placement)\(name)() {\n" + children.map { $0.scad(indent: indent + 1) }.joined() + "\(pad)}\n"
        }
        switch kind {
        case .box(let half, let round):
            if round > 0 { return "\(pad)\(placement)minkowski() { cube(\(v(half * 2)), center = true); sphere(r = \(n(round))); }\n" }
            return "\(pad)\(placement)cube(\(v(half * 2)), center = true);\n"
        case .cylinder(let radius, let half):
            return "\(pad)\(placement)cylinder(h = \(n(half * 2)), r = \(n(radius)), center = true);\n"
        case .cone(let bottom, let top, let half):
            return "\(pad)\(placement)cylinder(h = \(n(half * 2)), r1 = \(n(bottom)), r2 = \(n(top)), center = true);\n"
        case .sphere(let radius):
            return "\(pad)\(placement)sphere(r = \(n(radius)));\n"
        case .torus(let major, let minor):
            return "\(pad)\(placement)rotate_extrude() translate([\(n(major)), 0, 0]) circle(r = \(n(minor)));\n"
        case .extrude(let points, let half):
            let outline = points.map { "[\(n($0.x)), \(n($0.y))]" }.joined(separator: ", ")
            return "\(pad)\(placement)linear_extrude(height = \(n(half * 2)), center = true) polygon(points = [\(outline)]);\n"
        case .union: return group("union")
        case .subtract: return group("difference")
        case .intersect: return group("intersection")
        }
    }
}
