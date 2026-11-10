import Foundation
import simd

/// Turns a `SolidShape` into a closed triangle mesh, and measures how well a shape matches a scan.
enum SolidMesher {
    /// Meshes the part of `shape` inside the box `lo`...`hi` with a grid of `cells` along the longest
    /// side (surface nets: one vertex per grid cell the surface passes through). The result is closed
    /// even where the shape pokes out of the box. Coordinates are not moved, so the mesh lines up with
    /// the scan it was fitted to.
    static func mesh(_ shape: SolidShape, lo: SIMD3<Float>, hi: SIMD3<Float>, cells: Int, name: String) -> Mesh {
        let extent = hi - lo
        let h = max(extent.x, extent.y, extent.z, 1e-3) / Float(max(8, cells))
        let nx = Int((extent.x / h).rounded(.up)) + 2, ny = Int((extent.y / h).rounded(.up)) + 2, nz = Int((extent.z / h).rounded(.up)) + 2
        func node(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> { lo + SIMD3(Float(i), Float(j), Float(k)) * h }

        // Distances at the grid nodes. Far from the surface a whole block gets its centre's distance:
        // only the sign matters there, and it saves most of the work.
        var values = [Float](repeating: 0, count: nx * ny * nz)
        let block = 4
        let reach = 1.5 * Float(3).squareRoot() * h + 2 * h
        for bz in stride(from: 0, to: nz, by: block) {
            for by in stride(from: 0, to: ny, by: block) {
                for bx in stride(from: 0, to: nx, by: block) {
                    let middle = shape.distance(lo + SIMD3(Float(bx) + 1.5, Float(by) + 1.5, Float(bz) + 1.5) * h)
                    let far = abs(middle) > reach
                    for k in bz..<min(bz + block, nz) {
                        for j in by..<min(by + block, ny) {
                            for i in bx..<min(bx + block, nx) {
                                var d = far ? middle : shape.distance(node(i, j, k))
                                // The outermost nodes count as outside, which closes the mesh at the box.
                                if i == 0 || j == 0 || k == 0 || i == nx - 1 || j == ny - 1 || k == nz - 1 { d = max(d, h * 0.01) }
                                values[i + nx * (j + ny * k)] = d
                            }
                        }
                    }
                }
            }
        }
        func value(_ i: Int, _ j: Int, _ k: Int) -> Float { values[i + nx * (j + ny * k)] }

        // One vertex per cell the surface crosses: the average of the crossings on the cell's edges.
        let cx = nx - 1, cy = ny - 1
        var cellVertex = [Int32](repeating: -1, count: cx * cy * (nz - 1))
        var vertices: [SIMD3<Float>] = []
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        var corner = [Float](repeating: 0, count: 8)
        var position = [SIMD3<Float>](repeating: .zero, count: 8)
        for k in 0..<(nz - 1) {
            for j in 0..<cy {
                for i in 0..<cx {
                    var inside = 0
                    for c in 0..<8 {
                        corner[c] = value(i + (c & 1), j + ((c >> 1) & 1), k + (c >> 2))
                        if corner[c] < 0 { inside += 1 }
                    }
                    if inside == 0 || inside == 8 { continue }
                    for c in 0..<8 { position[c] = node(i + (c & 1), j + ((c >> 1) & 1), k + (c >> 2)) }
                    var sum = SIMD3<Float>.zero
                    var crossings: Float = 0
                    for (a, b) in edges where (corner[a] < 0) != (corner[b] < 0) {
                        let t = corner[a] / (corner[a] - corner[b])
                        sum += position[a] + (position[b] - position[a]) * t
                        crossings += 1
                    }
                    cellVertex[i + cx * (j + cy * k)] = Int32(vertices.count)
                    vertices.append(sum / crossings)
                }
            }
        }

        // One quad per grid edge the surface crosses, joining the four cells around that edge.
        var faces: [SIMD3<Int>] = []
        func cell(_ i: Int, _ j: Int, _ k: Int) -> Int { Int(cellVertex[i + cx * (j + cy * k)]) }
        func quad(_ a: Int, _ b: Int, _ c: Int, _ d: Int, startsInside: Bool) {
            guard a >= 0, b >= 0, c >= 0, d >= 0 else { return }
            if startsInside { faces.append(SIMD3(a, b, c)); faces.append(SIMD3(a, c, d)) }
            else { faces.append(SIMD3(a, c, b)); faces.append(SIMD3(a, d, c)) }
        }
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    let here = value(i, j, k) < 0
                    if i < nx - 1, j > 0, k > 0, j < ny - 1, k < nz - 1, here != (value(i + 1, j, k) < 0) {
                        quad(cell(i, j - 1, k - 1), cell(i, j, k - 1), cell(i, j, k), cell(i, j - 1, k), startsInside: here)
                    }
                    if j < ny - 1, i > 0, k > 0, i < nx - 1, k < nz - 1, here != (value(i, j + 1, k) < 0) {
                        quad(cell(i - 1, j, k - 1), cell(i - 1, j, k), cell(i, j, k), cell(i, j, k - 1), startsInside: here)
                    }
                    if k < nz - 1, i > 0, j > 0, i < nx - 1, j < ny - 1, here != (value(i, j, k + 1) < 0) {
                        quad(cell(i - 1, j - 1, k), cell(i, j - 1, k), cell(i, j, k), cell(i - 1, j, k), startsInside: here)
                    }
                }
            }
        }

        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for vertex in vertices { low = simd_min(low, vertex); high = simd_max(high, vertex) }
        return Mesh(vertices: vertices, faces: faces, name: name, bounds: vertices.isEmpty ? .zero : high - low)
    }

    /// Volume enclosed by a mesh whose triangles face outwards. Negative when they face inwards.
    static func volume(_ mesh: Mesh) -> Float {
        var total: Double = 0
        for face in mesh.faces {
            let a = mesh.vertices[face.x], b = mesh.vertices[face.y], c = mesh.vertices[face.z]
            total += Double(simd_dot(a, simd_cross(b, c))) / 6
        }
        return Float(total)
    }
}

/// How far a rebuilt shape is from the scan it came from, in the scan's units (millimetres).
struct ShapeFit {
    /// Scan surface to rebuilt surface: catches a missing feature, a wrong size or a wrong position.
    let meanScanToModel: Float
    let p95ScanToModel: Float
    /// Positive when the scan mostly lies outside the rebuilt part (the part is too small).
    let bias: Float
    /// Rebuilt surface to scan surface: catches material the scan does not have.
    let meanModelToScan: Float
    /// Scan points furthest from the rebuilt surface. `signed` > 0: the scan is outside the part there.
    let worst: [(point: SIMD3<Float>, signed: Float)]

    /// One number to compare attempts by. Lower is better.
    var score: Float { meanScanToModel + meanModelToScan }

    static func measure(shape: SolidShape, scan: Mesh, model: Mesh) -> ShapeFit {
        let scanPoints = sample(scan.vertices, limit: 20_000)
        let signed = scanPoints.map { shape.distance($0) }
        let magnitudes = signed.map { abs($0) }.sorted()
        let mean = magnitudes.reduce(0, +) / Float(max(1, magnitudes.count))
        let p95 = magnitudes.isEmpty ? 0 : magnitudes[min(magnitudes.count - 1, magnitudes.count * 95 / 100)]
        let bias = signed.reduce(0, +) / Float(max(1, signed.count))

        // The worst places, spread out so they do not all describe the same miss.
        let size = max(scan.bounds.x, scan.bounds.y, scan.bounds.z)
        var worst: [(point: SIMD3<Float>, signed: Float)] = []
        for index in signed.indices.sorted(by: { abs(signed[$0]) > abs(signed[$1]) }) {
            if worst.count == 8 { break }
            let point = scanPoints[index]
            if worst.allSatisfy({ simd_distance($0.point, point) > size / 8 }) { worst.append((point, signed[index])) }
        }

        // Nearest scan point for each rebuilt vertex, through a grid of buckets.
        let cellSize = max(size / 64, 1e-3)
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3(Int32((p.x / cellSize).rounded(.down)), Int32((p.y / cellSize).rounded(.down)), Int32((p.z / cellSize).rounded(.down))) }
        var buckets: [SIMD3<Int32>: [SIMD3<Float>]] = [:]
        for point in sample(scan.vertices, limit: 150_000) { buckets[key(point), default: []].append(point) }
        let reach: Int32 = 2
        let cap = cellSize * Float(reach)
        var total: Float = 0
        let modelPoints = sample(model.vertices, limit: 20_000)
        for point in modelPoints {
            let home = key(point)
            var nearest = cap
            for dz in -reach...reach { for dy in -reach...reach { for dx in -reach...reach {
                guard let bucket = buckets[home &+ SIMD3(dx, dy, dz)] else { continue }
                for other in bucket { nearest = min(nearest, simd_distance(point, other)) }
            } } }
            total += nearest
        }
        return ShapeFit(meanScanToModel: mean, p95ScanToModel: p95, bias: bias,
                        meanModelToScan: total / Float(max(1, modelPoints.count)), worst: worst)
    }

    private static func sample(_ points: [SIMD3<Float>], limit: Int) -> [SIMD3<Float>] {
        guard points.count > limit else { return points }
        return stride(from: 0, to: points.count, by: points.count / limit + 1).map { points[$0] }
    }
}
