import Foundation
import simd

/// Decides which camera frames become photos. Pure rules, no ARKit, so they are unit tested.
///
/// The aim is a set of sharp, well-exposed photos that cover the scene without redundancy, while the phone
/// stays cool enough to keep going. Source quality is never lowered to save work: under heat the policy takes
/// photos less often, and at the limit it pauses and says why.
public struct CapturePolicy {
    public enum Thermal: Int, Comparable {
        case nominal, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Skip: Equatable {
        case tracking
        case tooFast
        case tooSoon
        case sameViewpoint
        case blurry
        case longExposure
        case limitReached
        case tooHot

        /// Short guidance for the person holding the phone, nil for skips that need no message.
        public var guidance: String? {
            switch self {
            case .tracking: return "Tracking is poor. Move slower and point at textured surfaces."
            case .blurry: return "Hold steadier: the last frames were blurry."
            case .longExposure: return "Too dark for sharp photos. Add light."
            case .tooHot: return "The phone is hot. Capture is paused until it cools down."
            case .limitReached: return "Photo limit reached. Finish the scan."
            case .tooFast, .tooSoon, .sameViewpoint: return nil
            }
        }
    }

    public enum Decision: Equatable {
        case take
        case skip(Skip)
    }

    public struct Frame {
        public var transform: simd_float4x4
        public var time: TimeInterval
        public var trackingNormal: Bool
        /// Mean absolute luma gradient over a central crop (see `sharpness(lumaRows:...)`). nil if not measured.
        public var sharpness: Float?
        public var exposureDuration: TimeInterval
        public init(transform: simd_float4x4, time: TimeInterval, trackingNormal: Bool, sharpness: Float?, exposureDuration: TimeInterval) {
            self.transform = transform; self.time = time; self.trackingNormal = trackingNormal
            self.sharpness = sharpness; self.exposureDuration = exposureDuration
        }
    }

    public var maxPhotos = 400
    public var minimumDistance: Float = 0.06
    public var minimumTurn: Float = 0.14  // radians, about 8 degrees
    public var baseInterval: TimeInterval = 0.4
    public var maximumSpeed: Float = 0.35  // meters per second
    public var maximumTurnRate: Float = 0.8  // radians per second
    /// A frame whose sharpness is below this share of the recent median is rejected as blurry.
    public var sharpnessRatio: Float = 0.6
    /// Longer exposures than this (about 1/30 s) blur with hand shake.
    public var maximumExposure: TimeInterval = 1.0 / 30.0
    /// Sharpness values of accepted photos used for the median. Needs this many before the gate applies.
    public var sharpnessWindow = 8
    public var minimumSamplesForGate = 4

    private(set) var accepted: [simd_float4x4] = []
    private var recentSharpness: [Float] = []
    private var previous: (transform: simd_float4x4, time: TimeInterval)?
    private var lastTaken: TimeInterval?

    public init() {}

    public var photoCount: Int { accepted.count }

    /// Minimum seconds between photos for the current heat. Slower when warm, none when critical.
    public func interval(thermal: Thermal) -> TimeInterval {
        switch thermal {
        case .nominal, .fair: return baseInterval
        case .serious: return baseInterval * 2.5
        case .critical: return .infinity
        }
    }

    /// Evaluates a frame. Call for every frame; it tracks motion between calls. A `.take` is recorded, so call
    /// `evaluate` only for frames that will actually be saved when it says take.
    /// `busy` says the previous photo is still being written: the frame is skipped, but motion is still tracked.
    /// `measureSharpness` is only called when every cheaper rule has passed, so most frames never pay for it.
    public mutating func evaluate(
        _ frame: Frame, thermal: Thermal, busy: Bool = false, measureSharpness: (() -> Float?)? = nil
    ) -> Decision {
        defer { previous = (frame.transform, frame.time) }
        if thermal == .critical { return .skip(.tooHot) }
        if accepted.count >= maxPhotos { return .skip(.limitReached) }
        guard frame.trackingNormal else { return .skip(.tracking) }

        if let previous, frame.time > previous.time {
            let dt = Float(frame.time - previous.time)
            let speed = simd_distance(Self.position(frame.transform), Self.position(previous.transform)) / dt
            let turn = Self.angle(Self.forward(frame.transform), Self.forward(previous.transform)) / dt
            if speed > maximumSpeed || turn > maximumTurnRate { return .skip(.tooFast) }
        }
        if busy { return .skip(.tooSoon) }
        if let lastTaken, frame.time - lastTaken < interval(thermal: thermal) { return .skip(.tooSoon) }
        if frame.exposureDuration > maximumExposure { return .skip(.longExposure) }

        // Against every earlier photo, not just the last: coming back to a spot already covered adds nothing.
        if accepted.contains(where: {
            simd_distance(Self.position(frame.transform), Self.position($0)) < minimumDistance
                && Self.angle(Self.forward(frame.transform), Self.forward($0)) < minimumTurn
        }) { return .skip(.sameViewpoint) }

        let sharpness = frame.sharpness ?? measureSharpness?()
        if let sharpness, recentSharpness.count >= minimumSamplesForGate {
            let sorted = recentSharpness.sorted()
            let median = sorted[sorted.count / 2]
            if sharpness < median * sharpnessRatio { return .skip(.blurry) }
        }

        accepted.append(frame.transform)
        lastTaken = frame.time
        if let sharpness {
            recentSharpness.append(sharpness)
            if recentSharpness.count > sharpnessWindow { recentSharpness.removeFirst() }
        }
        return .take
    }

    // MARK: Sharpness

    /// Mean absolute horizontal+vertical gradient of an 8-bit luma plane, over a central square crop sampled
    /// at every pixel. Higher is sharper. Only meaningful relative to other frames of the same scene, which
    /// is how `evaluate` uses it. `rows` gives access to row `y` as `width` bytes.
    public static func sharpness(width: Int, height: Int, crop: Int = 384, pixel: (Int, Int) -> UInt8) -> Float {
        let side = min(crop, width - 1, height - 1)
        guard side > 2 else { return 0 }
        let x0 = (width - side) / 2, y0 = (height - side) / 2
        var total = 0
        for y in y0..<(y0 + side - 1) {
            for x in x0..<(x0 + side - 1) {
                let p = Int(pixel(x, y))
                total += abs(p - Int(pixel(x + 1, y))) + abs(p - Int(pixel(x, y + 1)))
            }
        }
        return Float(total) / Float((side - 1) * (side - 1))
    }

    // MARK: Math

    static func position(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }
    static func forward(_ m: simd_float4x4) -> SIMD3<Float> { -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) }
    static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { acos(max(-1, min(1, simd_dot(a, b)))) }
}
