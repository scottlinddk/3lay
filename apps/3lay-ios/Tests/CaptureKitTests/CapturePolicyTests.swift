import XCTest
import simd
@testable import CaptureKit

final class CapturePolicyTests: XCTestCase {
    private func pose(x: Float = 0, yaw: Float = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(x, 0, 0, 1)
        return m
    }

    private func frame(_ t: TimeInterval, x: Float = 0, yaw: Float = 0, sharp: Float? = 10, exposure: TimeInterval = 0.01,
                       tracking: Bool = true) -> CapturePolicy.Frame {
        .init(transform: pose(x: x, yaw: yaw), time: t, trackingNormal: tracking, sharpness: sharp, exposureDuration: exposure)
    }

    func testFirstFrameIsTakenAndNearDuplicatesAreNot() {
        var p = CapturePolicy()
        XCTAssertEqual(p.evaluate(frame(0), thermal: .nominal), .take)
        // 1 s later, 1 cm away and the same direction: nothing new.
        XCTAssertEqual(p.evaluate(frame(1, x: 0.01), thermal: .nominal), .skip(.sameViewpoint))
        XCTAssertEqual(p.evaluate(frame(2, x: 0.2), thermal: .nominal), .take)
    }

    func testReturningToAnEarlierViewpointIsRecognised() {
        var p = CapturePolicy()
        _ = p.evaluate(frame(0, x: 0), thermal: .nominal)
        _ = p.evaluate(frame(1, x: 0.2), thermal: .nominal)
        _ = p.evaluate(frame(2, x: 0.4), thermal: .nominal)
        // Back where the first photo was (slowly enough to pass the speed gate): the last photo is 0.4 m
        // away, but the first is not.
        XCTAssertEqual(p.evaluate(frame(5, x: 0.005), thermal: .nominal), .skip(.sameViewpoint))
    }

    func testTurningInPlaceIsNewInformation() {
        var p = CapturePolicy()
        _ = p.evaluate(frame(0), thermal: .nominal)
        XCTAssertEqual(p.evaluate(frame(1, yaw: 0.3), thermal: .nominal), .take)
    }

    func testFastMotionTrackingAndIntervalAreRejected() {
        var p = CapturePolicy()
        _ = p.evaluate(frame(0), thermal: .nominal)
        XCTAssertEqual(p.evaluate(frame(1, tracking: false), thermal: .nominal), .skip(.tracking))
        XCTAssertEqual(p.evaluate(frame(1.1, x: 0.5), thermal: .nominal), .skip(.tooFast))  // 5 m/s
        var q = CapturePolicy()
        _ = q.evaluate(frame(0), thermal: .nominal)
        XCTAssertEqual(q.evaluate(frame(0.3, x: 0.05), thermal: .nominal), .skip(.tooSoon))  // 0.3 s < 0.4 s
    }

    func testBlurryFramesAreRejectedRelativeToRecentPhotos() {
        var p = CapturePolicy()
        for i in 0..<5 { XCTAssertEqual(p.evaluate(frame(Double(i) * 2, x: Float(i) * 0.3, sharp: 10), thermal: .nominal), .take) }
        XCTAssertEqual(p.evaluate(frame(20, x: 3, sharp: 4), thermal: .nominal), .skip(.blurry))  // 40% of the median
        XCTAssertEqual(p.evaluate(frame(22, x: 3.3, sharp: 8), thermal: .nominal), .take)
        // Different scene brightness/texture changes the median over time instead of a fixed threshold.
    }

    func testGateDoesNotApplyBeforeEnoughSamples() {
        var p = CapturePolicy()
        XCTAssertEqual(p.evaluate(frame(0, sharp: 10), thermal: .nominal), .take)
        XCTAssertEqual(p.evaluate(frame(2, x: 0.3, sharp: 1), thermal: .nominal), .take)
    }

    func testLongExposureIsRejected() {
        var p = CapturePolicy()
        XCTAssertEqual(p.evaluate(frame(0, exposure: 0.1), thermal: .nominal), .skip(.longExposure))
    }

    func testHeatSlowsThenPausesButNeverLowersQuality() {
        var p = CapturePolicy()
        XCTAssertEqual(p.interval(thermal: .nominal), 0.4)
        XCTAssertEqual(p.interval(thermal: .serious), 1.0, accuracy: 1e-9)
        _ = p.evaluate(frame(0), thermal: .nominal)
        XCTAssertEqual(p.evaluate(frame(0.6, x: 0.15), thermal: .serious), .skip(.tooSoon))  // fine when nominal, too soon when warm
        XCTAssertEqual(p.evaluate(frame(1.5, x: 0.4), thermal: .serious), .take)
        XCTAssertEqual(p.evaluate(frame(10, x: 1), thermal: .critical), .skip(.tooHot))
        XCTAssertNotNil(CapturePolicy.Skip.tooHot.guidance)
    }

    func testPhotoLimit() {
        var p = CapturePolicy()
        p.maxPhotos = 2
        _ = p.evaluate(frame(0), thermal: .nominal)
        _ = p.evaluate(frame(2, x: 0.3), thermal: .nominal)
        XCTAssertEqual(p.evaluate(frame(4, x: 0.6), thermal: .nominal), .skip(.limitReached))
    }

    func testSharpnessIsHigherForDetailThanForFlatImages() {
        let flat = CapturePolicy.sharpness(width: 64, height: 64, crop: 32) { _, _ in 100 }
        let checker = CapturePolicy.sharpness(width: 64, height: 64, crop: 32) { x, y in (x + y) % 2 == 0 ? 0 : 255 }
        let soft = CapturePolicy.sharpness(width: 64, height: 64, crop: 32) { x, _ in UInt8(min(255, x * 4)) }
        XCTAssertEqual(flat, 0)
        XCTAssertGreaterThan(checker, soft)
        XCTAssertGreaterThan(soft, flat)
    }

    func testFrameThatAddsNoCoverageIsSkippedButUnknownCoverageIsNot() {
        var p = CapturePolicy()
        XCTAssertEqual(p.evaluate(frame(0), thermal: .nominal, coverageGain: { nil }), .take)  // no mesh yet
        XCTAssertEqual(p.evaluate(frame(1, x: 0.3), thermal: .nominal, coverageGain: { 0.01 }), .skip(.noNewCoverage))
        XCTAssertEqual(p.evaluate(frame(2, x: 0.3), thermal: .nominal, coverageGain: { 0.5 }), .take)
        XCTAssertNil(CapturePolicy.Skip.noNewCoverage.guidance)
    }

    func testCoverageIsNotMeasuredWhenACheaperRuleAlreadySkips() {
        var p = CapturePolicy()
        var asked = false
        _ = p.evaluate(frame(0, tracking: false), thermal: .nominal, coverageGain: { asked = true; return 1 })
        XCTAssertFalse(asked)
    }
}
