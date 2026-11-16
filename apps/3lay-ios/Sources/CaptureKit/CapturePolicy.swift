import Foundation
import simd

/// Decides which camera frames become photos. Pure rules, no ARKit, so they are unit tested.
///
/// The aim is a set of sharp, well-exposed photos that cover the scene without redundancy, while the phone
/// stays cool enough to keep going. Source quality is never lowered to save work: under heat the policy takes
/// photos less often, and at the limit it pauses and says why.
///
/// Sharpness is judged in physical terms first: the smear the camera's own motion causes during the exposure,
/// in pixels (`CameraMotion.blurPixels`). A photo is taken in a moment when that is small. The older relative
/// sharpness gate stays as a second check for what motion cannot explain (focus, a moving subject).
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
        /// The photo would not add enough newly covered surface (see `CoverageMap`).
        case noNewCoverage
        case blurry
        /// The camera's motion during the exposure would smear the photo by more than the current budget.
        case motionBlur
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
            // `motionBlur` is silent per frame: the policy waits for a steadier moment, which usually comes within
            // a second. The capture screen speaks up when it does not (`motionBlurGuidance`).
            case .tooFast, .tooSoon, .sameViewpoint, .noNewCoverage, .motionBlur: return nil
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
        /// Focal length in pixels of the image that would be saved. nil skips the motion-blur gate.
        public var focalLength: Float?
        /// Distance to the nearer surfaces in view, meters (`CameraMotion.representativeDepth`). nil if unknown.
        public var sceneDepth: Float?
        public init(
            transform: simd_float4x4, time: TimeInterval, trackingNormal: Bool, sharpness: Float?,
            exposureDuration: TimeInterval, focalLength: Float? = nil, sceneDepth: Float? = nil
        ) {
            self.transform = transform; self.time = time; self.trackingNormal = trackingNormal
            self.sharpness = sharpness; self.exposureDuration = exposureDuration
            self.focalLength = focalLength; self.sceneDepth = sceneDepth
        }
    }

    public var maxPhotos = 400
    public var minimumDistance: Float = 0.06
    public var minimumTurn: Float = 0.14  // radians, about 8 degrees
    /// Square meters of not-yet-covered surface a photo must add when coverage is known.
    public var minimumCoverageGain: Float = 0.06
    public var baseInterval: TimeInterval = 0.4
    public var maximumSpeed: Float = 0.35  // meters per second
    public var maximumTurnRate: Float = 0.8  // radians per second
    /// Motion smear (pixels, see `CameraMotion.blurPixels`) a photo may have while photos are coming steadily.
    /// 1.5 px on a 1920 px wide frame is indistinguishable from a still camera.
    public var sharpBlurPixels: Float = 1.5
    /// The most smear ever accepted, once the scan has gone without a photo for a while. Above this a photo
    /// harms a reconstruction more than its coverage helps.
    public var acceptableBlurPixels: Float = 4
    /// Seconds without a photo before the budget starts to widen from `sharpBlurPixels`, and the seconds it then
    /// takes to reach `acceptableBlurPixels`. Without this a dim room, where no hand is steady enough for the
    /// strict budget, would never get a photo at all.
    public var blurRelaxDelay: TimeInterval = 1.5
    public var blurRelaxDuration: TimeInterval = 1.5
    /// How long a scan may go without a photo, refused for motion blur, before the person is asked to slow down.
    public var motionBlurGuidanceDelay: TimeInterval = 3
    public static let motionBlurGuidance = "Slow down or pause for a moment so a sharp photo can be taken."
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
    private var firstSeen: TimeInterval?
    private var blurBlockedSince: TimeInterval?

    /// Motion between the two most recent frames, and the smear it means for the latest one. nil when unknown
    /// (first frame, a gap between frames, or no focal length given). Valid right after `evaluate`, so the
    /// caller can store it with the photo it just took.
    public private(set) var lastMotion: CameraMotion?
    public private(set) var lastBlurPixels: Float?

    public init() {}

    /// The smear a photo may have at `time`: strict while photos are coming, wider after a dry spell.
    public func blurBudget(at time: TimeInterval) -> Float {
        guard let reference = lastTaken ?? firstSeen else { return sharpBlurPixels }
        let waited = time - reference - blurRelaxDelay
        guard waited > 0 else { return sharpBlurPixels }
        let share = blurRelaxDuration > 0 ? Float(min(1, waited / blurRelaxDuration)) : 1
        return sharpBlurPixels + (acceptableBlurPixels - sharpBlurPixels) * share
    }

    /// True once the camera's motion has kept the scan from taking a photo for `motionBlurGuidanceDelay`.
    public func needsMotionBlurGuidance(at time: TimeInterval) -> Bool {
        guard let blurBlockedSince else { return false }
        return time - blurBlockedSince >= motionBlurGuidanceDelay
    }

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
    /// `coverageGain` returns the square meters of surface this view would newly cover, or nil while that is not
    /// known (no mesh yet); a known gain under `minimumCoverageGain` skips the frame. It runs after the cheap
    /// rules and before the sharpness measurement.
    public mutating func evaluate(
        _ frame: Frame, thermal: Thermal, busy: Bool = false, coverageGain: (() -> Float?)? = nil,
        measureSharpness: (() -> Float?)? = nil
    ) -> Decision {
        defer { previous = (frame.transform, frame.time) }
        if firstSeen == nil { firstSeen = frame.time }
        lastMotion = previous.flatMap { CameraMotion(from: $0.transform, to: frame.transform, elapsed: frame.time - $0.time) }
        lastBlurPixels = frame.focalLength.flatMap { focal in
            lastMotion?.blurPixels(exposure: frame.exposureDuration, focalLength: focal, sceneDepth: frame.sceneDepth)
        }
        let decision = decide(frame, thermal: thermal, busy: busy, coverageGain: coverageGain, measureSharpness: measureSharpness)
        // Moving too fast and smearing are the same problem to the person holding the phone. "Too soon" says
        // nothing either way; any other outcome means motion is not what is holding the scan up.
        if decision == .skip(.motionBlur) || decision == .skip(.tooFast) {
            if blurBlockedSince == nil { blurBlockedSince = frame.time }
        } else if decision != .skip(.tooSoon) {
            blurBlockedSince = nil
        }
        return decision
    }

    private mutating func decide(
        _ frame: Frame, thermal: Thermal, busy: Bool, coverageGain: (() -> Float?)?, measureSharpness: (() -> Float?)?
    ) -> Decision {
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

        // After the viewpoint check, so a phone resting on a view it already has is not asked to hold still.
        if let blur = lastBlurPixels, blur > blurBudget(at: frame.time) { return .skip(.motionBlur) }

        if let gain = coverageGain?(), gain < minimumCoverageGain { return .skip(.noNewCoverage) }

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

    public static func position(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }
    public static func forward(_ m: simd_float4x4) -> SIMD3<Float> { -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) }
    public static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { acos(max(-1, min(1, simd_dot(a, b)))) }
}
