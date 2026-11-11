import XCTest
import simd
@testable import CaptureKit

final class ScanCatalogTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func catalog() -> ScanCatalog { ScanCatalog(url: root.appendingPathComponent("catalog.json"), root: root) }

    private func makeLidarFolder(_ name: String, complete: Bool) throws {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("mesh"), withIntermediateDirectories: true)
        if complete {
            try Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
            try Data([1]).write(to: folder.appendingPathComponent("mesh/scan.ply"))
        }
    }

    func testRecordsSurviveRelaunchAndKeepJobId() throws {
        let c = catalog()
        let record = ScanRecord(kind: .lidar, status: .saved, folder: "a", serverJobId: "job-1")
        try c.upsert(record)
        XCTAssertEqual(catalog().record(id: record.id)?.serverJobId, "job-1")
    }

    func testReconcileRecoversCompleteAndFlagsIncomplete() throws {
        try makeLidarFolder("done", complete: true)
        try makeLidarFolder("torn", complete: false)
        let c = catalog()
        let done = ScanRecord(kind: .lidar, status: .saving, folder: "done")
        let torn = ScanRecord(kind: .lidar, status: .saving, folder: "torn")
        let gone = ScanRecord(kind: .lidar, status: .saved, folder: "missing")
        let sending = ScanRecord(kind: .lidar, status: .sending, folder: "done")
        for r in [done, torn, gone, sending] { try c.upsert(r) }

        let result = try catalog().reconcile()
        let after = catalog()
        XCTAssertEqual(after.record(id: done.id)?.status, .saved)
        XCTAssertEqual(after.record(id: sending.id)?.status, .saved)
        XCTAssertEqual(after.record(id: torn.id)?.status, .incomplete)
        XCTAssertNil(after.record(id: gone.id))
        XCTAssertEqual(result.dropped, [gone.id])
        XCTAssertEqual(result.incomplete, [torn.id])
        // Reconciling never deletes files.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("torn").path))
    }

    func testDiscardRemovesFilesAndRecord() throws {
        try makeLidarFolder("x", complete: true)
        let c = catalog()
        let r = ScanRecord(kind: .lidar, status: .saved, folder: "x")
        try c.upsert(r)
        XCTAssertGreaterThan(c.totalStorageBytes(), 0)
        try c.discard(id: r.id)
        XCTAssertNil(c.record(id: r.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("x").path))
    }

    func testRelativePathIsStoredUnderRoot() {
        XCTAssertEqual(catalog().relativePath(of: root.appendingPathComponent("lidar/abc")), "lidar/abc")
    }
}

final class MeshChunkWriterTests: XCTestCase {
    private func floats(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testChunksAreRotatedToZUpAndIndicesOffset() throws {
        // Two identical chunks; the second must have its indices shifted by the first's vertex count.
        let vertices = floats([0, 0, 0, 1, 0, 0, 0, 1, 0])
        let faces = withUnsafeBytes(of: [UInt16(0), 1, 2]) { Data($0) }
        let chunk = MeshChunk(
            transform: matrix_identity_float4x4, vertexData: vertices, vertexCount: 3,
            faceData: faces, faceCount: 1, bytesPerIndex: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chunks-\(UUID().uuidString).ply")
        defer { try? FileManager.default.removeItem(at: url) }
        let summary = try PLYWriter.write(chunks: [chunk, chunk], to: url)
        XCTAssertEqual(summary, PLYWriter.Summary(vertexCount: 6, triangleCount: 2))

        let data = try Data(contentsOf: url)
        let marker = try XCTUnwrap(data.range(of: Data("end_header\n".utf8)))
        let body = data[marker.upperBound...]
        XCTAssertEqual(body.count, 6 * 12 + 2 * 13)
        // Vertex 2 is (0, 1, 0) in ARKit (Y up) and must be (0, -0, 1) in the Z-up file.
        let y = body.dropFirst(2 * 12 + 4).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        let z = body.dropFirst(2 * 12 + 8).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        XCTAssertEqual(y, 0)
        XCTAssertEqual(z, 1)
        // Second face starts after 6 vertices and 1 face (13 bytes); its first index is 3.
        let second = body.dropFirst(6 * 12 + 13 + 1).prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(second, 3)
    }

    func testFailureLeavesNoPartialFile() throws {
        let bad = MeshChunk(
            transform: matrix_identity_float4x4, vertexData: floats([0, 0, 0]), vertexCount: 1,
            faceData: withUnsafeBytes(of: [UInt16(0), 1, 2]) { Data($0) }, faceCount: 1, bytesPerIndex: 2)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try PLYWriter.write(chunks: [bad], to: dir.appendingPathComponent("scan.ply")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testTruncatedChunkIsRejected() {
        let short = MeshChunk(
            transform: matrix_identity_float4x4, vertexData: Data(count: 4), vertexCount: 3,
            faceData: Data(), faceCount: 1, bytesPerIndex: 4)
        XCTAssertFalse(short.isConsistent)
        XCTAssertThrowsError(try PLYWriter.write(
            chunks: [short], to: FileManager.default.temporaryDirectory.appendingPathComponent("no.ply")))
    }
}

final class ScanRetentionTests: XCTestCase {
    func testPruneRemovesOnlyOldDeliveredScans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["old", "new", "unsent"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let c = ScanCatalog(url: root.appendingPathComponent("c.json"), root: root)
        let now = Date()
        let old = ScanRecord(kind: .object, createdAt: now.addingTimeInterval(-10 * 86400), status: .sent, folder: "old")
        let recent = ScanRecord(kind: .object, createdAt: now, status: .sent, folder: "new")
        let unsent = ScanRecord(kind: .object, createdAt: now.addingTimeInterval(-30 * 86400), status: .saved, folder: "unsent")
        for r in [old, recent, unsent] { try c.upsert(r) }
        XCTAssertEqual(try c.pruneDelivered(now: now), [old.id])
        XCTAssertNil(c.record(id: old.id))
        XCTAssertNotNil(c.record(id: recent.id))
        XCTAssertNotNil(c.record(id: unsent.id), "an unsent scan is never pruned, however old")
    }
}
