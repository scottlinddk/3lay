import XCTest
import simd
@testable import CaptureKit

/// The rules that protect dimensional accuracy: motion smear, pose corrections and what counts as a rigid pose.
final class CaptureAccuracyTests: XCTestCase {
    private let device = CaptureManifest.Device(model: "iPhone", systemVersion: "17", appVersion: "1", hasLiDAR: true)

    private func pose(x: Float = 0, angle: Float = 0, axis: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: angle, axis: axis))
        m.columns.3 = SIMD4(x, 0, 0, 1)
        return m
    }

    /// A 1920 px wide video frame (focal length 1500 px) exposed for 1/60 s.
    private func frame(_ t: TimeInterval, x: Float = 0, tracking: Bool = true, depth: Float? = nil) -> CapturePolicy.Frame {
        .init(transform: pose(x: x), time: t, trackingNormal: tracking, sharpness: 10, exposureDuration: 1.0 / 60.0,
              focalLength: 1500, sceneDepth: depth)
    }

    // MARK: CameraMotion

    func testRotationAngleIsPreciseForTinyTurnsAndCountsRoll() {
        // One milliradian: acos((trace - 1) / 2) in Float would be off by several percent here.
        XCTAssertEqual(CameraMotion.rotationAngle(from: pose(), to: pose(angle: 0.001)), 0.001, accuracy: 2e-6)
        // Roll about the optical axis leaves the viewing direction unchanged but still smears the image.
        XCTAssertEqual(CameraMotion.rotationAngle(from: pose(), to: pose(angle: 0.2, axis: SIMD3(0, 0, 1))), 0.2, accuracy: 1e-5)
        XCTAssertEqual(CameraMotion.rotationAngle(from: pose(angle: 0.4), to: pose(angle: 0.1)), 0.3, accuracy: 1e-5)
        XCTAssertEqual(CameraMotion.rotationAngle(from: pose(x: 3), to: pose(x: -2)), 0, accuracy: 1e-6)
    }

    func testMotionBetweenFrames() throws {
        let motion = try XCTUnwrap(CameraMotion(from: pose(), to: pose(x: 0.01, angle: 0.002), elapsed: 0.02))
        XCTAssertEqual(motion.speed, 0.5, accuracy: 1e-4)
        XCTAssertEqual(motion.angularSpeed, 0.1, accuracy: 1e-3)
        // Not in time order, or too far apart to describe one exposure.
        XCTAssertNil(CameraMotion(from: pose(), to: pose(x: 1), elapsed: 0))
        XCTAssertNil(CameraMotion(from: pose(), to: pose(x: 1), elapsed: -1))
        XCTAssertNil(CameraMotion(from: pose(), to: pose(x: 1), elapsed: 1))
    }

    func testBlurInPixels() {
        // Turning 0.1 rad/s for 1/60 s at 1500 px focal length: 1500 * 0.1 / 60 = 2.5 px.
        XCTAssertEqual(CameraMotion(speed: 0, angularSpeed: 0.1).blurPixels(exposure: 1.0 / 60.0, focalLength: 1500), 2.5, accuracy: 1e-3)
        // Moving 0.3 m/s past a surface 2 m away: 1500 * 0.3 / 2 / 60 = 3.75 px. Nearer surfaces smear more.
        let sliding = CameraMotion(speed: 0.3, angularSpeed: 0)
        XCTAssertEqual(sliding.blurPixels(exposure: 1.0 / 60.0, focalLength: 1500, sceneDepth: 2), 3.75, accuracy: 1e-3)
        XCTAssertEqual(sliding.blurPixels(exposure: 1.0 / 60.0, focalLength: 1500, sceneDepth: 0.5), 15, accuracy: 1e-3)
        // Unknown or invalid depth falls back to 1 m; the two terms add.
        XCTAssertEqual(sliding.blurPixels(exposure: 1.0 / 60.0, focalLength: 1500), 7.5, accuracy: 1e-3)
        XCTAssertEqual(sliding.blurPixels(exposure: 1.0 / 60.0, focalLength: 1500, sceneDepth: .nan), 7.5, accuracy: 1e-3)
        XCTAssertEqual(CameraMotion(speed: 0.3, angularSpeed: 0.1).blurPixels(exposure: 1.0 / 60.0, focalLength: 1500), 10, accuracy: 1e-3)
        // A shorter exposure smears less: the reason a fixed speed limit is the wrong rule.
        XCTAssertEqual(sliding.blurPixels(exposure: 1.0 / 600.0, focalLength: 1500), 0.75, accuracy: 1e-3)
        XCTAssertEqual(sliding.blurPixels(exposure: 0, focalLength: 1500), 0)
    }

    func testRepresentativeDepthIsTheLowerQuartileOfValidValues() {
        XCTAssertEqual(CameraMotion.representativeDepth([0, .nan, 4, 1, 2, 3, -1, .infinity]), 2)
        XCTAssertEqual(CameraMotion.representativeDepth([5]), 5)
        XCTAssertNil(CameraMotion.representativeDepth([0, .nan]))
        XCTAssertNil(CameraMotion.representativeDepth([]))
    }

    // MARK: Policy

    func testPhotoIsRefusedWhileTheCameraSmearsAndTakenWhenItIsSteady() throws {
        var p = CapturePolicy()
        XCTAssertEqual(p.evaluate(frame(0), thermal: .nominal), .take)
        XCTAssertNil(p.lastBlurPixels)  // nothing to compare the first frame with

        // A frame without tracking is never taken; it only tells the policy where the camera was 1/30 s before.
        _ = p.evaluate(frame(1.967, x: 0.59, tracking: false), thermal: .nominal)
        // 1 cm in 1/30 s is 0.3 m/s: under the speed limit, but 7.5 px of smear at 1/60 s.
        XCTAssertEqual(p.evaluate(frame(2, x: 0.6), thermal: .nominal), .skip(.motionBlur))
        XCTAssertEqual(try XCTUnwrap(p.lastBlurPixels), 7.5, accuracy: 0.2)
        XCTAssertEqual(try XCTUnwrap(p.lastMotion).speed, 0.3, accuracy: 0.01)
        XCTAssertEqual(p.photoCount, 1)

        // The same step, almost at rest: 1 mm in 1/30 s is 0.75 px.
        _ = p.evaluate(frame(2.967, x: 0.899, tracking: false), thermal: .nominal)
        XCTAssertEqual(p.evaluate(frame(3, x: 0.9), thermal: .nominal), .take)
        XCTAssertEqual(try XCTUnwrap(p.lastBlurPixels), 0.75, accuracy: 0.1)
    }

    func testDistantSceneToleratesTheSameHandSpeed() {
        var p = CapturePolicy()
        _ = p.evaluate(frame(0), thermal: .nominal)
        _ = p.evaluate(frame(1.967, x: 0.59, tracking: false, depth: 10), thermal: .nominal)
        // 0.3 m/s past surfaces 10 m away is 0.75 px.
        XCTAssertEqual(p.evaluate(frame(2, x: 0.6, depth: 10), thermal: .nominal), .take)
    }

    func testFramesWithoutFocalLengthAreNotJudgedForMotionBlur() {
        var p = CapturePolicy()
        func plain(_ t: TimeInterval, x: Float, tracking: Bool = true) -> CapturePolicy.Frame {
            .init(transform: pose(x: x), time: t, trackingNormal: tracking, sharpness: 10, exposureDuration: 1.0 / 60.0)
        }
        _ = p.evaluate(plain(0, x: 0), thermal: .nominal)
        _ = p.evaluate(plain(1.967, x: 0.59, tracking: false), thermal: .nominal)
        XCTAssertEqual(p.evaluate(plain(2, x: 0.6), thermal: .nominal), .take)
        XCTAssertNil(p.lastBlurPixels)
        XCTAssertNotNil(p.lastMotion)
    }

    func testBlurBudgetWidensOnlyAfterADrySpell() {
        var p = CapturePolicy()
        XCTAssertEqual(p.blurBudget(at: 100), 1.5)  // nothing seen yet
        _ = p.evaluate(frame(10), thermal: .nominal)  // photo at t = 10
        XCTAssertEqual(p.blurBudget(at: 10.5), 1.5)
        XCTAssertEqual(p.blurBudget(at: 11.5), 1.5)
        XCTAssertEqual(p.blurBudget(at: 12.25), 2.75, accuracy: 1e-4)  // halfway through the 1.5 s ramp
        XCTAssertEqual(p.blurBudget(at: 13), 4, accuracy: 1e-4)
        XCTAssertEqual(p.blurBudget(at: 60), 4)  // never beyond the acceptable limit
    }

    func testSlowDownGuidanceAppearsOnlyAfterMotionHasBlockedPhotosForAWhile() {
        var p = CapturePolicy()
        XCTAssertNil(CapturePolicy.Skip.motionBlur.guidance)  // silent per frame
        // Walking at a steady 0.3 m/s, 30 frames a second: every frame smears 7.5 px, above even the wide budget.
        var decisions: [CapturePolicy.Decision] = []
        for i in 0...150 {
            let t = Double(i) / 30
            decisions.append(p.evaluate(frame(t, x: Float(i) * 0.01), thermal: .nominal))
            if i == 60 { XCTAssertFalse(p.needsMotionBlurGuidance(at: t)) }  // 2 s in: still waiting quietly
        }
        XCTAssertEqual(p.photoCount, 1)  // only the first frame
        XCTAssertEqual(decisions.last, .skip(.motionBlur))
        XCTAssertTrue(p.needsMotionBlurGuidance(at: 5))
        // Holding still gets a photo and ends the advice.
        XCTAssertEqual(p.evaluate(frame(5 + 1.0 / 30, x: 1.5), thermal: .nominal), .take)
        XCTAssertFalse(p.needsMotionBlurGuidance(at: 6))
    }

    // MARK: Rigid poses

    func testOnlyTrueRigidMotionsPassAsCameraPoses() {
        var moved = pose(x: 4, angle: 1.1, axis: simd_normalize(SIMD3(1, 2, 3)))
        moved.columns.3 = SIMD4(4, -2, 7, 1)
        XCTAssertTrue(LidarBundleValidator.isRigid(matrix_identity_float4x4))
        XCTAssertTrue(LidarBundleValidator.isRigid(moved))

        // A uniform 1% stretch is a 1% dimensional error. The old check (2% on one axis) let it through.
        var stretched = moved
        stretched.columns.0 *= 1.01; stretched.columns.1 *= 1.01; stretched.columns.2 *= 1.01
        stretched.columns.3 = moved.columns.3
        XCTAssertFalse(LidarBundleValidator.isRigid(stretched))

        var oneAxis = matrix_identity_float4x4
        oneAxis.columns.1.y = 1.01  // the old check only measured the first axis
        XCTAssertFalse(LidarBundleValidator.isRigid(oneAxis))

        var sheared = matrix_identity_float4x4
        sheared.columns.1.x = 0.01
        XCTAssertFalse(LidarBundleValidator.isRigid(sheared))

        var mirrored = matrix_identity_float4x4
        mirrored.columns.2.z = -1
        XCTAssertFalse(LidarBundleValidator.isRigid(mirrored))

        var scaledW = matrix_identity_float4x4
        scaledW.columns.3.w = 2  // homogeneous scale: every point lands at half its distance
        XCTAssertFalse(LidarBundleValidator.isRigid(scaledW))

        XCTAssertFalse(LidarBundleValidator.isRigidPose([1, 0, 0]))
        XCTAssertTrue(LidarBundleValidator.isRigidPose(moved.flatMatrix))
    }

    // MARK: Pose correction and the accuracy summary

    func testPoseCorrectionMeasuresHowFarARKitMovedAPose() throws {
        let correction = PoseCorrection(recorded: pose(x: 1), refined: pose(x: 1.03, angle: 0.01))
        XCTAssertEqual(correction.translation, 0.03, accuracy: 1e-5)
        XCTAssertEqual(correction.rotation, 0.01, accuracy: 1e-5)
        let unchanged = PoseCorrection(recorded: pose(x: 1, angle: 0.3), refined: pose(x: 1, angle: 0.3))
        XCTAssertEqual(unchanged.translation, 0, accuracy: 1e-6)
        XCTAssertEqual(unchanged.rotation, 0, accuracy: 1e-5)
        XCTAssertNil(PoseCorrection(recorded: [1, 2], refined: pose().flatMatrix))
    }

    private func photo(_ n: Int, blur: Float? = nil, refinedBy offset: Float? = nil) -> LidarManifest.Photo {
        LidarManifest.Photo(
            file: String(format: "photos/%04d.jpg", n), width: 1920, height: 1440, timestamp: Double(n),
            transform: pose(x: Float(n)).flatMatrix, intrinsics: [1500, 1500, 960, 720],
            motion: blur.map { .init(speed: 0.1, angularSpeed: 0.05, blurPixels: $0) },
            refinedTransform: offset.map { pose(x: Float(n) + $0).flatMatrix })
    }

    func testAccuracySummary() throws {
        let photos = [photo(1, blur: 0.5, refinedBy: 0), photo(2, blur: 3, refinedBy: 0.02), photo(3, blur: 1, refinedBy: 0.05), photo(4)]
        let accuracy = LidarManifest.Accuracy(photos: photos, trackingInterruptions: 2)
        XCTAssertEqual(accuracy.trackingInterruptions, 2)
        XCTAssertEqual(accuracy.medianBlurPixels, 1)
        XCTAssertEqual(accuracy.maximumBlurPixels, 3)
        XCTAssertEqual(accuracy.refinedPoses, 3)
        XCTAssertEqual(try XCTUnwrap(accuracy.medianPoseCorrection), 0.02, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(accuracy.maximumPoseCorrection), 0.05, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(accuracy.maximumPoseRotation), 0, accuracy: 1e-5)

        let empty = LidarManifest.Accuracy(photos: [photo(1)], trackingInterruptions: 0)
        XCTAssertNil(empty.medianBlurPixels)
        XCTAssertNil(empty.maximumPoseCorrection)
        XCTAssertEqual(empty.refinedPoses, 0)
    }

    func testAccuracyFieldsMakeAVersion4ManifestThatRoundTrips() throws {
        let photos = [photo(1, blur: 0.5, refinedBy: 0.01), photo(2)]
        let m = LidarManifest(
            createdAt: Date(timeIntervalSince1970: 0), device: device, vertexCount: 3, triangleCount: 1, photos: photos,
            accuracy: .init(photos: photos, trackingInterruptions: 1))
        XCTAssertEqual(m.format, "3lay-lidar/4")
        XCTAssertEqual(m.capabilities, ["motion/1", "refined-poses/1", "accuracy/1"])
        XCTAssertNotNil(m.meshFromWorld)
        let decoded = try CaptureManifest.decoder().decode(LidarManifest.self, from: CaptureManifest.encoder().encode(m))
        XCTAssertEqual(decoded, m)

        // Without any of the new fields the format stays what it was.
        let plain = LidarManifest(createdAt: Date(timeIntervalSince1970: 0), device: device, vertexCount: 3, triangleCount: 1, photos: [photo(1)])
        XCTAssertEqual(plain.format, "3lay-lidar/1")
        XCTAssertNil(plain.accuracy)
    }

    func testValidatorChecksRefinedPosesAndBlur() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("accuracy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("mesh"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("mesh/scan.ply"))
        try Data([1]).write(to: folder.appendingPathComponent("photos/0001.jpg"))
        func manifest(_ p: LidarManifest.Photo) -> LidarManifest {
            LidarManifest(createdAt: Date(timeIntervalSince1970: 0), device: device, vertexCount: 3, triangleCount: 1, photos: [p])
        }

        var good = photo(1, blur: 0.5, refinedBy: 0.01)
        XCTAssertEqual(LidarBundleValidator.validate(manifest: manifest(good), in: folder), [])

        var stretched = matrix_identity_float4x4
        stretched.columns.0.x = 1.01
        good.refinedTransform = stretched.flatMatrix
        XCTAssertTrue(LidarBundleValidator.validate(manifest: manifest(good), in: folder).contains { $0.message.contains("Refined transform") })

        var smeared = photo(1, blur: -Float.infinity)
        smeared.refinedTransform = nil
        XCTAssertTrue(LidarBundleValidator.validate(manifest: manifest(smeared), in: folder).contains { $0.message.contains("Motion blur") })
    }
}
