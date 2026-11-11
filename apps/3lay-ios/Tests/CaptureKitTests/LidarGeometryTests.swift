import XCTest
import simd
@testable import CaptureKit

final class LidarGeometryTests: XCTestCase {
    private let k = LidarGeometry.Intrinsics(fx: 1000, fy: 1000, cx: 960, cy: 720)

    private func assertEqual(_ a: Float?, _ b: Float, accuracy: Float = 1e-3, _ message: String = "", line: UInt = #line) {
        guard let a else { return XCTFail("nil: \(message)", line: line) }
        XCTAssertEqual(a, b, accuracy: accuracy, message, line: line)
    }

    func testPointAheadAndUpProjectsAboveTheCentre() {
        // ARKit camera: +Y up, looks down -Z. A point 2 m ahead, 5 cm up and 10 cm right.
        let p = LidarGeometry.project(world: SIMD3(0.1, 0.05, -2), cameraToWorld: matrix_identity_float4x4, intrinsics: k)
        assertEqual(p?.u, 1010)  // 1000 * 0.1 / 2 + 960
        assertEqual(p?.v, 695)   // up is smaller v: 720 - 1000 * 0.05 / 2
        assertEqual(p?.depth, 2)
    }

    func testTranslationMovesTheCameraNotThePoint() {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(1, 0, 0, 1)
        let p = LidarGeometry.project(world: SIMD3(1.1, 0.05, -2), cameraToWorld: pose, intrinsics: k)
        assertEqual(p?.u, 1010)
        assertEqual(p?.v, 695)
    }

    func testCameraTurnedLeftSeesWhatIsAtNegativeX() {
        // Yaw +90 degrees about Y: the camera's forward (-Z) becomes world -X.
        let yaw = simd_float4x4(columns: (SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 0, 1)))
        let p = LidarGeometry.project(world: SIMD3(-3, 0, 0), cameraToWorld: yaw, intrinsics: k)
        assertEqual(p?.u, 960)
        assertEqual(p?.v, 720)
        assertEqual(p?.depth, 3)
    }

    func testPointBehindTheCameraDoesNotProject() {
        XCTAssertNil(LidarGeometry.project(world: SIMD3(0, 0, 2), cameraToWorld: matrix_identity_float4x4, intrinsics: k))
    }

    func testUnprojectInvertsProject() throws {
        let pose = simd_float4x4(columns: (SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0.3, -0.2, 0.5, 1)))
        let world = SIMD3<Float>(-2.2, 0.4, 0.9)
        let p = try XCTUnwrap(LidarGeometry.project(world: world, cameraToWorld: pose, intrinsics: k))
        let back = LidarGeometry.unproject(u: p.u, v: p.v, depth: p.depth, cameraToWorld: pose, intrinsics: k)
        XCTAssertEqual(simd_distance(world, back), 0, accuracy: 1e-3)
    }

    func testIntrinsicsScaleWithResolution() {
        let full = LidarGeometry.Intrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720)
        let depth = full.scaled(from: (1920, 1440), to: (256, 192))
        XCTAssertEqual(depth.fx, 200, accuracy: 0.01)
        XCTAssertEqual(depth.cx, 128, accuracy: 0.01)
        XCTAssertEqual(depth.cy, 96, accuracy: 0.01)
        // The scaled intrinsics see the same direction: the optical axis still lands in the middle.
        let ahead = LidarGeometry.project(world: SIMD3(0, 0, -1), cameraToWorld: matrix_identity_float4x4, intrinsics: depth)
        assertEqual(ahead?.u, 128)
        assertEqual(ahead?.v, 96)
    }

    func testMeshAxesAreZUpAndAgreeWithTheMatrix() {
        // World up (+Y) must be mesh up (+Z); world forward (-Z) must be mesh +Y.
        XCTAssertEqual(LidarGeometry.meshPoint(fromWorld: SIMD3(0, 1, 0)), SIMD3(0, 0, 1))
        XCTAssertEqual(LidarGeometry.meshPoint(fromWorld: SIMD3(0, 0, -1)), SIMD3(0, 1, 0))
        let p = SIMD3<Float>(1, 2, 3)
        let viaMatrix = LidarGeometry.meshFromWorld * SIMD4(p, 1)
        XCTAssertEqual(SIMD3(viaMatrix.x, viaMatrix.y, viaMatrix.z), LidarGeometry.meshPoint(fromWorld: p))
        XCTAssertEqual(LidarGeometry.meshFromWorld.determinant, 1, accuracy: 1e-6)  // a rotation: winding is kept
    }

    func testFlatMatrixRoundTrips() {
        let m = simd_float4x4(columns: (SIMD4(1, 2, 3, 4), SIMD4(5, 6, 7, 8), SIMD4(9, 10, 11, 12), SIMD4(13, 14, 15, 16)))
        XCTAssertEqual(simd_float4x4(flat: m.flatMatrix), m)
        XCTAssertNil(simd_float4x4(flat: [1, 2, 3]))
        XCTAssertNil(simd_float4x4(flat: Array(repeating: Float.nan, count: 16)))
    }
}

final class LidarBundleFormatTests: XCTestCase {
    private let device = CaptureManifest.Device(model: "iPhone", systemVersion: "17", appVersion: "1", hasLiDAR: true)
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("mesh"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("depth"), withIntermediateDirectories: true)
        try? Data([1]).write(to: folder.appendingPathComponent("mesh/scan.ply"))
        try? Data([1]).write(to: folder.appendingPathComponent("photos/0001.jpg"))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func photo(depth: LidarManifest.Depth? = nil, transform: [Float]? = nil) -> LidarManifest.Photo {
        LidarManifest.Photo(
            file: "photos/0001.jpg", width: 1920, height: 1440, timestamp: 1,
            transform: transform ?? matrix_identity_float4x4.flatMatrix, intrinsics: [1500, 1500, 960, 720],
            trackingState: "normal", exposure: .init(duration: 0.01, offset: 0, ambientIntensity: 1000), depth: depth)
    }

    private func depthRef() -> LidarManifest.Depth {
        LidarManifest.Depth(file: "depth/0001.depth", confidenceFile: "depth/0001.conf", width: 256, height: 192,
                            intrinsics: [200, 200, 128, 96])
    }

    private func writeDepth(bytes: Int = 256 * 192 * 4, confidence: Int = 256 * 192) {
        try? Data(count: bytes).write(to: folder.appendingPathComponent("depth/0001.depth"))
        try? Data(count: confidence).write(to: folder.appendingPathComponent("depth/0001.conf"))
    }

    private func manifest(_ photos: [LidarManifest.Photo]) -> LidarManifest {
        LidarManifest(createdAt: Date(timeIntervalSince1970: 0), device: device, vertexCount: 3, triangleCount: 1, photos: photos)
    }

    func testDepthBundleIsVersion2AndDeclaresItsCapabilities() throws {
        let m = manifest([photo(depth: depthRef())])
        XCTAssertEqual(m.format, "3lay-lidar/2")
        XCTAssertEqual(m.capabilities, ["depth/1"])
        XCTAssertEqual(m.meshFromWorld, LidarGeometry.meshFromWorld.flatMatrix)
        let decoded = try CaptureManifest.decoder().decode(LidarManifest.self, from: CaptureManifest.encoder().encode(m))
        XCTAssertEqual(decoded, m)
    }

    func testVersion1ManifestStillDecodes() throws {
        let v1 = """
        {"format":"3lay-lidar/1","createdAt":"1970-01-01T00:00:00Z","device":{"model":"iPhone","systemVersion":"17","appVersion":"1","hasLiDAR":true},
         "units":"meters","meshFile":"mesh/scan.ply","vertexCount":3,"triangleCount":1,
         "photos":[{"file":"photos/0001.jpg","width":1920,"height":1440,"timestamp":1,"transform":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],"intrinsics":[1500,1500,960,720]}]}
        """
        let m = try CaptureManifest.decoder().decode(LidarManifest.self, from: Data(v1.utf8))
        XCTAssertEqual(m.format, "3lay-lidar/1")
        XCTAssertNil(m.photos[0].depth)
        XCTAssertNil(m.capabilities)
        XCTAssertEqual(LidarBundleValidator.validate(manifest: m, in: folder), [])
    }

    func testValidBundlePasses() {
        writeDepth()
        XCTAssertEqual(LidarBundleValidator.validate(manifest: manifest([photo(depth: depthRef())]), in: folder), [])
    }

    func testMissingAndWrongSizedDepthAreReported() {
        let m = manifest([photo(depth: depthRef())])
        XCTAssertTrue(LidarBundleValidator.validate(manifest: m, in: folder).contains { $0.message.contains("Depth map") && $0.message.contains("missing") })
        writeDepth(bytes: 100)
        XCTAssertTrue(LidarBundleValidator.validate(manifest: m, in: folder).contains { $0.message.contains("expected \(256 * 192 * 4)") })
    }

    func testNonRigidTransformAndBadIntrinsicsAreReported() {
        writeDepth()
        var scaled = matrix_identity_float4x4
        scaled.columns.0.x = 3  // a scaled axis is not a camera pose
        var bad = photo(depth: depthRef(), transform: scaled.flatMatrix)
        bad.intrinsics = [0, 1500, 960, 720]
        let issues = LidarBundleValidator.validate(manifest: manifest([bad]), in: folder).map(\.message)
        XCTAssertTrue(issues.contains { $0.contains("rigid") })
        XCTAssertTrue(issues.contains { $0.contains("Focal length") })
    }

    func testMisalignedDepthAspectIsReported() {
        writeDepth()
        var depth = depthRef()
        depth.height = 256  // square depth for a 4:3 photo cannot line up
        try? Data(count: 256 * 256 * 4).write(to: folder.appendingPathComponent("depth/0001.depth"))
        try? Data(count: 256 * 256).write(to: folder.appendingPathComponent("depth/0001.conf"))
        XCTAssertTrue(LidarBundleValidator.validate(manifest: manifest([photo(depth: depth)]), in: folder).contains { $0.message.contains("aspect") })
    }

    func testPathEscapingTheBundleIsRejected() {
        var p = photo()
        p.file = "../outside.jpg"
        XCTAssertTrue(LidarBundleValidator.validate(manifest: manifest([p]), in: folder).contains { $0.message.contains("leaves the bundle") })
    }
}
