import XCTest
import simd
@testable import CaptureKit

final class DepthKeyframePolicyTests: XCTestCase {
    private func pose(x: Float = 0, yaw: Float = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(x, 0, 0, 1)
        return m
    }

    func testTakesAboutFivePerSecondWhileMovingAndNothingWhileStill() {
        var p = DepthKeyframePolicy()
        XCTAssertTrue(p.shouldTake(time: 0, transform: pose(), trackingNormal: true, thermal: .nominal, busy: false))
        XCTAssertFalse(p.shouldTake(time: 0.1, transform: pose(x: 0.1), trackingNormal: true, thermal: .nominal, busy: false))  // too soon
        XCTAssertFalse(p.shouldTake(time: 0.3, transform: pose(x: 0.001), trackingNormal: true, thermal: .nominal, busy: false))  // still
        XCTAssertTrue(p.shouldTake(time: 0.4, transform: pose(x: 0.05), trackingNormal: true, thermal: .nominal, busy: false))
        XCTAssertTrue(p.shouldTake(time: 0.7, transform: pose(x: 0.05, yaw: 0.1), trackingNormal: true, thermal: .nominal, busy: false))  // turned
        XCTAssertEqual(p.count, 3)
    }

    func testHeatSlowsItAndCriticalStopsIt() {
        var p = DepthKeyframePolicy()
        XCTAssertTrue(p.shouldTake(time: 0, transform: pose(), trackingNormal: true, thermal: .nominal, busy: false))
        XCTAssertFalse(p.shouldTake(time: 0.5, transform: pose(x: 1), trackingNormal: true, thermal: .serious, busy: false))  // needs 0.8 s
        XCTAssertTrue(p.shouldTake(time: 0.9, transform: pose(x: 1), trackingNormal: true, thermal: .serious, busy: false))
        XCTAssertFalse(p.shouldTake(time: 100, transform: pose(x: 5), trackingNormal: true, thermal: .critical, busy: false))
    }

    func testPoorTrackingBusyWriterAndTheLimitAllSkip() {
        var p = DepthKeyframePolicy()
        XCTAssertFalse(p.shouldTake(time: 0, transform: pose(), trackingNormal: false, thermal: .nominal, busy: false))
        XCTAssertFalse(p.shouldTake(time: 0, transform: pose(), trackingNormal: true, thermal: .nominal, busy: true))
        p.maximumFrames = 1
        XCTAssertTrue(p.shouldTake(time: 1, transform: pose(), trackingNormal: true, thermal: .nominal, busy: false))
        XCTAssertFalse(p.shouldTake(time: 2, transform: pose(x: 1), trackingNormal: true, thermal: .nominal, busy: false))
    }
}

final class HighResPolicyTests: XCTestCase {
    private func view(x: Float = 0, yaw: Float = 0, width: Int = 4032, exposure: Double = 0.01, tracking: Bool = true) -> HighResPolicy.View {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(x, 0, 0, 1)
        return .init(transform: m, width: width, exposureDuration: exposure, trackingNormal: tracking)
    }

    func testRequestsAreRareAndOnlyOnACoolPhone() {
        let p = HighResPolicy()
        func ask(_ now: TimeInterval, last: TimeInterval? = nil, thermal: CapturePolicy.Thermal = .nominal,
                 inFlight: Bool = false, constrained: Bool = false, supported: Bool = true) -> Bool {
            p.shouldRequest(now: now, lastRequest: last, thermal: thermal, inFlight: inFlight, budgetConstrained: constrained, supported: supported)
        }
        XCTAssertTrue(ask(10))
        XCTAssertFalse(ask(11, last: 10))
        XCTAssertTrue(ask(13.5, last: 10))
        XCTAssertFalse(ask(10, thermal: .fair))
        XCTAssertFalse(ask(10, inFlight: true))
        XCTAssertFalse(ask(10, constrained: true))
        XCTAssertFalse(ask(10, supported: false))
    }

    func testStillReplacesTheHeldFrameOnlyForTheSameViewAtHigherResolutionWithoutMoreBlur() {
        let p = HighResPolicy()
        let held = view(width: 1920, exposure: 0.01)
        XCTAssertTrue(p.accepts(still: view(x: 0.05, yaw: 0.05, width: 4032, exposure: 0.012), replacing: held))
        XCTAssertFalse(p.accepts(still: view(width: 1920), replacing: held))                 // not larger
        XCTAssertFalse(p.accepts(still: view(x: 0.5), replacing: held))                      // moved away
        XCTAssertFalse(p.accepts(still: view(yaw: 0.5), replacing: held))                    // turned away
        XCTAssertFalse(p.accepts(still: view(exposure: 0.04), replacing: held))              // hand shake
        XCTAssertFalse(p.accepts(still: view(exposure: 0.03), replacing: held))              // 3x the held exposure
        XCTAssertFalse(p.accepts(still: view(tracking: false), replacing: held))
    }
}
