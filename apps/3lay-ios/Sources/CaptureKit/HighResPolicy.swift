import Foundation
import simd

/// Rules for swapping a video frame for a full-resolution still (`ARSession.captureHighResolutionFrame`).
///
/// A still is slow and hot: it is requested rarely and only on a cool phone, and it replaces the held video
/// frame only if it shows the same view in a clearly larger and no more blurred image. Pure rules, unit tested.
public struct HighResPolicy {
    public var minimumInterval: TimeInterval = 3
    /// A still taken over this exposure time (about 1/30 s) is too blurred by hand shake to be worth keeping.
    public var maximumExposure: TimeInterval = 1.0 / 30.0
    /// The still must show the view within this distance (meters) and angle (radians, about 12 degrees) of the held frame.
    public var maximumDistance: Float = 0.2
    public var maximumAngle: Float = Float.pi / 15
    /// Exposure the still may have relative to the held frame (longer exposure means more motion blur).
    public var exposureTolerance: Double = 1.5

    public init() {}

    public struct View {
        public var transform: simd_float4x4
        public var width: Int
        public var exposureDuration: TimeInterval
        public var trackingNormal: Bool
        public init(transform: simd_float4x4, width: Int, exposureDuration: TimeInterval, trackingNormal: Bool = true) {
            self.transform = transform; self.width = width
            self.exposureDuration = exposureDuration; self.trackingNormal = trackingNormal
        }
    }

    /// Whether to ask for a still now.
    public func shouldRequest(
        now: TimeInterval, lastRequest: TimeInterval?, thermal: CapturePolicy.Thermal, inFlight: Bool,
        budgetConstrained: Bool, supported: Bool
    ) -> Bool {
        guard supported, !inFlight, !budgetConstrained, thermal == .nominal else { return false }
        if let lastRequest, now - lastRequest < minimumInterval { return false }
        return true
    }

    /// Whether the still should replace the held video frame.
    public func accepts(still: View, replacing held: View) -> Bool {
        guard still.trackingNormal, still.width > held.width, still.exposureDuration <= maximumExposure else { return false }
        guard still.exposureDuration <= max(held.exposureDuration, 1.0 / 60.0) * exposureTolerance else { return false }
        let distance = simd_distance(CapturePolicy.position(still.transform), CapturePolicy.position(held.transform))
        let angle = CapturePolicy.angle(CapturePolicy.forward(still.transform), CapturePolicy.forward(held.transform))
        return distance < maximumDistance && angle < maximumAngle
    }
}
