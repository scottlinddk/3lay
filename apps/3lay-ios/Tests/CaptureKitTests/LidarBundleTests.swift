import XCTest
@testable import CaptureKit

final class LidarBundleTests: XCTestCase {
    func testPLYWriterProducesBinaryLayoutTheMacReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lidar-\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: url) }
        try PLYWriter.write(
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)], triangles: [SIMD3(0, 1, 2)], to: url)
        let data = try Data(contentsOf: url)
        let marker = try XCTUnwrap(data.range(of: Data("end_header\n".utf8)))
        let header = String(decoding: data[..<marker.lowerBound], as: UTF8.self)
        XCTAssertTrue(header.contains("format binary_little_endian 1.0"))
        XCTAssertTrue(header.contains("element vertex 3"))
        XCTAssertTrue(header.contains("property list uchar int vertex_indices"))
        // 3 vertices x 12 bytes, then 1 face x (1 count byte + 3 x 4 bytes).
        XCTAssertEqual(data.count - marker.upperBound, 3 * 12 + 13)
        XCTAssertEqual(data[marker.upperBound + 36], 3)
    }

    func testPLYWriterRejectsEmptyAndBrokenMeshes() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("never.ply")
        XCTAssertThrowsError(try PLYWriter.write(vertices: [], triangles: [], to: url))
        XCTAssertThrowsError(try PLYWriter.write(vertices: [SIMD3(0, 0, 0)], triangles: [SIMD3(0, 1, 2)], to: url))
    }

    func testLidarManifestRoundTrips() throws {
        let device = CaptureManifest.Device(model: "iPhone", systemVersion: "17", appVersion: "1", hasLiDAR: true)
        let photo = LidarManifest.Photo(file: "photos/0001.jpg", width: 1920, height: 1440, timestamp: 1.5,
                                        transform: Array(repeating: 0, count: 16), intrinsics: [1, 1, 0, 0])
        let manifest = LidarManifest(createdAt: Date(timeIntervalSince1970: 0), device: device, vertexCount: 3, triangleCount: 1, photos: [photo])
        let decoded = try CaptureManifest.decoder().decode(LidarManifest.self, from: CaptureManifest.encoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.format, "3lay-lidar/1")
        XCTAssertEqual(decoded.units, "meters")
    }
}
