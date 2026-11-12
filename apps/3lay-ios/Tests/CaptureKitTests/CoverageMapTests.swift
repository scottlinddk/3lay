import XCTest
import simd
@testable import CaptureKit

final class CoverageMapTests: XCTestCase {
    /// A flat wall at z = -2 facing +Z, sampled on a 5 cm grid, x and y from 0 to 1.
    private func wall(size: Int = 20) -> [CoverageMap.Sample] {
        (0..<size).flatMap { i in (0..<size).map { j in
            CoverageMap.Sample(position: SIMD3(Float(i) * 0.05 + 0.025, Float(j) * 0.05 + 0.025, -2), normal: SIMD3(0, 0, 1))
        } }
    }

    /// A camera at `position` looking down -Z (the identity orientation), 1920 x 1440 with a 1500 px focal length.
    private func photo(
        at position: SIMD3<Float> = SIMD3(0.5, 0.5, 0), sharpness: Float = 1, depth: CoveragePhoto.DepthGrid? = nil
    ) -> CoveragePhoto {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(position, 1)
        return CoveragePhoto(
            cameraToWorld: pose, intrinsics: .init(fx: 1500, fy: 1500, cx: 960, cy: 720), width: 1920, height: 1440,
            sharpness: sharpness, depth: depth)
    }

    func testIntegrateDeduplicatesCellsAndKeepsScores() {
        var map = CoverageMap()
        map.integrate(wall())
        XCTAssertEqual(map.cellCount, 400)
        map.add(photo())
        let covered = map.percent
        map.integrate(wall())  // the same surface again: no new cells, no lost score
        XCTAssertEqual(map.cellCount, 400)
        XCTAssertEqual(map.percent, covered)
    }

    func testCloseSharpPhotoCoversTheWallAndASecondOneAddsNothing() {
        var map = CoverageMap()
        map.integrate(wall())
        // 2 m away at 1500 px focal length: 1500 / 200 = 7.5 px/cm, above the 4 px/cm target.
        let first = photo()
        let predicted = map.gain(of: first)
        XCTAssertEqual(map.add(first), predicted, accuracy: 1e-5)
        XCTAssertEqual(predicted, 0.9, accuracy: 1e-3)  // the 1 m x 1 m wall, minus the 10% no-depth discount
        XCTAssertEqual(map.percent, 0)  // no depth: 0.9 of the target, so not yet done
        map.add(photo(at: SIMD3(0.5, 0.5, 0.01)))
        XCTAssertEqual(map.percent, 100)
        XCTAssertEqual(map.gain(of: photo(at: SIMD3(0.5, 0.5, 0.02))), 0, accuracy: 1e-6)
    }

    func testBlurryPhotoCountsForLess() {
        var map = CoverageMap()
        map.integrate(wall())
        XCTAssertLessThan(map.gain(of: photo(sharpness: 0.3)), map.gain(of: photo(sharpness: 1)))
    }

    func testFarPhotoGivesLessDetailThanTheTarget() {
        var map = CoverageMap()
        map.integrate(wall())
        // 4.5 m away: 1500 / 450 = 3.3 px/cm, about 0.83 of the target (and 0.9 without depth).
        let far = photo(at: SIMD3(0.5, 0.5, 2.5))
        let near = photo()
        XCTAssertLessThan(map.gain(of: far), map.gain(of: near))
        XCTAssertGreaterThan(map.gain(of: far), 0)
    }

    func testOutOfRangeBehindAndGrazingViewsAddNothing() {
        var map = CoverageMap()
        map.integrate(wall())
        XCTAssertEqual(map.gain(of: photo(at: SIMD3(0.5, 0.5, 3.5))), 0)  // 5.5 m: beyond maximumRange
        XCTAssertEqual(map.gain(of: photo(at: SIMD3(0.5, 0.5, -4))), 0)  // behind the wall, looking away
        // Standing 5 cm in front of the wall's plane and looking along it (toward -X): a grazing angle.
        var sideways = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        sideways.columns.3 = SIMD4(3, 0.5, -1.95, 1)
        let side = CoveragePhoto(
            cameraToWorld: sideways, intrinsics: .init(fx: 1500, fy: 1500, cx: 960, cy: 720), width: 1920, height: 1440)
        XCTAssertEqual(map.gain(of: side), 0)
    }

    func testSomethingInFrontBlocksTheView() {
        var map = CoverageMap()
        map.integrate(wall())
        // Depth map that sees a surface 1 m away everywhere: the wall at 2 m is hidden behind it.
        let blocked = CoveragePhoto.DepthGrid(
            width: 4, height: 3, values: Array(repeating: 1, count: 12), cameraToWorld: matrix_identity_float4x4,
            intrinsics: .init(fx: 3, fy: 3, cx: 2, cy: 1.5))
        XCTAssertEqual(map.gain(of: photo(depth: blocked)), 0)
        // Depth that agrees with the wall (2 m) confirms it and counts in full.
        let agrees = CoveragePhoto.DepthGrid(
            width: 4, height: 3, values: Array(repeating: 2, count: 12), cameraToWorld: matrix_identity_float4x4,
            intrinsics: .init(fx: 3, fy: 3, cx: 2, cy: 1.5))
        XCTAssertGreaterThan(map.gain(of: photo(depth: agrees)), map.gain(of: photo()))
    }

    func testBandsAndLookup() {
        var map = CoverageMap()
        map.integrate(wall())
        XCTAssertEqual(map.band(at: SIMD3(0.52, 0.52, -2)), .needsPhotos)
        XCTAssertNil(map.band(at: SIMD3(10, 10, 10)))
        map.add(photo(sharpness: 0.5))
        XCTAssertEqual(map.band(at: SIMD3(0.52, 0.52, -2)), .almost)  // 0.9 * 0.5 = 0.45
        map.add(photo(at: SIMD3(0.5, 0.5, 0.01)))
        map.add(photo(at: SIMD3(0.5, 0.5, 0.02)))
        XCTAssertEqual(map.band(at: SIMD3(0.52, 0.52, -2)), .done)
    }

    func testTooLittleSurfaceReportsZeroPercent() {
        var map = CoverageMap()
        map.integrate([.init(position: SIMD3(0, 0, -2), normal: SIMD3(0, 0, 1))])
        map.add(photo(at: SIMD3(0, 0, 0)))
        XCTAssertEqual(map.percent, 0)
    }

    func testPlateauNeedsDecentCoverageTimeAndNoProgress() {
        var p = CoveragePlateau()
        p.update(percent: 70, at: 0)
        XCTAssertFalse(p.isPlateau(at: 100))  // not scanning for 2 minutes yet
        p.update(percent: 70, at: 100)        // no progress
        XCTAssertTrue(p.isPlateau(at: 130))
        p.update(percent: 75, at: 131)        // progress resets the stall clock
        XCTAssertFalse(p.isPlateau(at: 150))
        XCTAssertTrue(p.isPlateau(at: 180))
        var low = CoveragePlateau()
        low.update(percent: 40, at: 0)
        XCTAssertFalse(low.isPlateau(at: 1000))  // stuck low is not "done", it needs more scanning
    }
}
