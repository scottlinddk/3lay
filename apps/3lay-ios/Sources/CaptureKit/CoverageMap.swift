import Foundation
import simd

/// How well the photos taken so far show the surfaces LiDAR has seen. Pure geometry, no ARKit, so it is unit tested.
///
/// The scene is a set of small surface cells (one per `cellSize` grid square of the LiDAR mesh, with a normal).
/// Each photo adds to the cells it shows well: close enough for detail, not at a grazing angle, sharp, and not
/// hidden behind something (checked against that photo's own depth). A cell is *done* when its score reaches
/// `doneScore`. The share of done area is the "photo detail" figure, and the gain a candidate photo would add
/// decides whether it is worth taking at all.
public struct CoveragePhoto {
    /// Low-resolution depth (meters along the optical axis, 0 = no value) used to tell if a surface is hidden.
    public struct DepthGrid {
        public var width: Int, height: Int
        public var values: [Float]
        public var worldToCamera: simd_float4x4
        public var intrinsics: LidarGeometry.Intrinsics
        public init(width: Int, height: Int, values: [Float], cameraToWorld: simd_float4x4, intrinsics: LidarGeometry.Intrinsics) {
            self.width = width; self.height = height; self.values = values
            self.worldToCamera = cameraToWorld.inverse; self.intrinsics = intrinsics
        }
    }

    public var worldToCamera: simd_float4x4
    public var position: SIMD3<Float>
    public var intrinsics: LidarGeometry.Intrinsics
    public var width: Float, height: Float
    /// 1 for a sharp photo, lower for a blurrier one.
    public var sharpness: Float
    public var depth: DepthGrid?

    public init(
        cameraToWorld: simd_float4x4, intrinsics: LidarGeometry.Intrinsics, width: Int, height: Int,
        sharpness: Float = 1, depth: DepthGrid? = nil
    ) {
        worldToCamera = cameraToWorld.inverse
        position = SIMD3(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)
        self.intrinsics = intrinsics
        self.width = Float(width); self.height = Float(height)
        self.sharpness = max(0, min(1, sharpness))
        self.depth = depth
    }
}

public struct CoverageMap {
    public struct Sample: Equatable {
        public var position: SIMD3<Float>
        public var normal: SIMD3<Float>
        public init(position: SIMD3<Float>, normal: SIMD3<Float>) { self.position = position; self.normal = normal }
    }

    public enum Band: Equatable { case needsPhotos, almost, done }

    // Tunables. The detail target is pixels per centimeter on the surface: 4 px/cm reads labels and trim edges.
    public let cellSize: Float
    public var targetPixelsPerCentimeter: Float = 4
    public var maximumRange: Float = 5
    public var minimumRange: Float = 0.15
    /// Smallest |cos| of the angle between the surface normal and the direction to the camera.
    public var minimumCosine: Float = 0.2
    public var doneScore: Float = 1
    public var almostScore: Float = 0.4
    /// Observed area under this (m²) reports 0%: too little seen to say anything.
    public var minimumAreaForPercent: Float = 0.5

    private var index: [SIMD3<Int32>: Int] = [:]
    private var positions: [SIMD3<Float>] = []
    private var normals: [SIMD3<Float>] = []
    private var scores: [Float] = []

    public init(cellSize: Float = 0.05) { self.cellSize = cellSize }

    public var cellCount: Int { positions.count }
    public var cellArea: Float { cellSize * cellSize }
    /// Observed surface area in square meters.
    public var observedArea: Float { Float(positions.count) * cellArea }

    /// The grid cell containing `p`. Lets a background job drop surface it has already reported.
    public func cellKey(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32((p.x / cellSize).rounded(.down)), Int32((p.y / cellSize).rounded(.down)), Int32((p.z / cellSize).rounded(.down)))
    }

    /// Adds newly seen surface. A cell that already exists keeps its score; its normal is refreshed.
    public mutating func integrate(_ samples: [Sample]) {
        for sample in samples where sample.position.x.isFinite && sample.position.y.isFinite && sample.position.z.isFinite {
            let length = simd_length(sample.normal)
            guard length > 1e-6 else { continue }
            let normal = sample.normal / length
            let k = cellKey(sample.position)
            if let i = index[k] {
                normals[i] = normal
            } else {
                index[k] = positions.count
                positions.append(sample.position)
                normals.append(normal)
                scores.append(0)
            }
        }
    }

    /// How much one photo adds to the cell at `i`, before the cap.
    func contribution(of photo: CoveragePhoto, toCell i: Int) -> Float {
        let point = positions[i]
        let c = photo.worldToCamera * SIMD4(point, 1)
        let d = -c.z
        guard d > minimumRange, d < maximumRange else { return 0 }
        let k = photo.intrinsics
        let u = k.fx * c.x / d + k.cx, v = k.cy - k.fy * c.y / d
        guard u >= 0, u < photo.width, v >= 0, v < photo.height else { return 0 }
        // The mesh normal can face either way, so only the angle to the view line matters.
        let toCamera = simd_normalize(photo.position - point)
        let cosine = abs(simd_dot(normals[i], toCamera))
        guard cosine > minimumCosine else { return 0 }

        var occlusion: Float = 0.9  // no depth to check against: count it, a little less
        if let g = photo.depth {
            let cg = g.worldToCamera * SIMD4(point, 1)
            let dg = -cg.z
            guard dg > 0.05 else { return 0 }
            let gu = Int((g.intrinsics.fx * cg.x / dg + g.intrinsics.cx).rounded(.down))
            let gv = Int((g.intrinsics.cy - g.intrinsics.fy * cg.y / dg).rounded(.down))
            if gu >= 0, gu < g.width, gv >= 0, gv < g.height {
                let surface = g.values[gv * g.width + gu]
                if surface > 0, dg > surface + 0.06 + 0.03 * surface { return 0 }  // something is in front
                occlusion = 1
            }
        }
        let pixelsPerCentimeter = k.fx * cosine / d / 100
        return min(1, pixelsPerCentimeter / targetPixelsPerCentimeter) * photo.sharpness * occlusion
    }

    /// Square meters of surface this photo would bring up to `doneScore`, without recording it.
    public func gain(of photo: CoveragePhoto) -> Float {
        var total: Float = 0
        for i in positions.indices where scores[i] < doneScore {
            let q = contribution(of: photo, toCell: i)
            if q > 0 { total += min(doneScore, scores[i] + q) - scores[i] }
        }
        return total * cellArea
    }

    /// Records a photo and returns the same gain `gain(of:)` would have reported.
    @discardableResult
    public mutating func add(_ photo: CoveragePhoto) -> Float {
        var total: Float = 0
        for i in positions.indices where scores[i] < doneScore {
            let q = contribution(of: photo, toCell: i)
            if q > 0 {
                let updated = min(doneScore, scores[i] + q)
                total += updated - scores[i]
                scores[i] = updated
            }
        }
        return total * cellArea
    }

    public func band(forScore score: Float) -> Band {
        score >= doneScore ? .done : (score >= almostScore ? .almost : .needsPhotos)
    }

    /// The score of the cell containing `point`, nil if LiDAR has not seen that spot.
    public func score(at point: SIMD3<Float>) -> Float? { index[cellKey(point)].map { scores[$0] } }

    public func band(at point: SIMD3<Float>) -> Band? { score(at: point).map(band(forScore:)) }

    /// Share (0 to 100) of observed area that is photographed well. Not the share of the room scanned.
    public var percent: Int {
        guard observedArea >= minimumAreaForPercent else { return 0 }
        let done = scores.reduce(0) { $0 + ($1 >= doneScore ? 1 : 0) }
        return Int((Float(done) / Float(scores.count) * 100).rounded())
    }
}

/// Says when more circling no longer helps: coverage is decent, the scan has gone on a while and the figure
/// has not moved for a good stretch. Times are seconds on any monotonic clock.
public struct CoveragePlateau {
    public var minimumPercent = 65
    public var minimumDuration: TimeInterval = 120
    public var stall: TimeInterval = 45

    private var started: TimeInterval?
    private var best = 0
    private var lastProgress: TimeInterval = 0

    public init() {}

    public mutating func update(percent: Int, at time: TimeInterval) {
        if started == nil { started = time; lastProgress = time }
        if percent > best { best = percent; lastProgress = time }
    }

    public func isPlateau(at time: TimeInterval) -> Bool {
        guard let started else { return false }
        return best >= minimumPercent && time - started > minimumDuration && time - lastProgress > stall
    }
}
