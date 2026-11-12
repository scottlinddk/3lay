import Foundation
import simd

/// Decides which frames also keep a depth map as a depth keyframe (`LidarManifest.depthFrames`).
///
/// Depth is cheap next to a photo and it is what the Mac uses for scale and alignment, so it is kept several
/// times a second while the phone moves, independent of the photo rate. A phone held still adds nothing, and a
/// warm phone does less. Pure rules, unit tested.
public struct DepthKeyframePolicy {
    public var interval: TimeInterval = 0.2  // up to 5 per second
    public var minimumDistance: Float = 0.03
    public var minimumTurn: Float = 0.05  // radians, about 3 degrees
    /// About 150 MB of Float16 depth plus confidence. A longer scan keeps the early frames and stops.
    public var maximumFrames = 1200

    private var last: (time: TimeInterval, transform: simd_float4x4)?
    public private(set) var count = 0

    public init() {}

    private func interval(for thermal: CapturePolicy.Thermal) -> TimeInterval {
        switch thermal {
        case .nominal: return interval
        case .fair: return interval * 1.5
        case .serious: return interval * 4
        case .critical: return .infinity
        }
    }

    /// True if this frame's depth should be kept. A `true` is recorded, so only call it for frames that will be
    /// saved when it says so. `busy` says the previous depth frame is still being written.
    public mutating func shouldTake(
        time: TimeInterval, transform: simd_float4x4, trackingNormal: Bool, thermal: CapturePolicy.Thermal, busy: Bool
    ) -> Bool {
        guard count < maximumFrames, trackingNormal, !busy else { return false }
        if let last {
            guard time - last.time >= interval(for: thermal) else { return false }
            let moved = simd_distance(CapturePolicy.position(transform), CapturePolicy.position(last.transform)) >= minimumDistance
            let turned = CapturePolicy.angle(CapturePolicy.forward(transform), CapturePolicy.forward(last.transform)) >= minimumTurn
            guard moved || turned else { return false }
        }
        last = (time, transform)
        count += 1
        return true
    }
}
