import XCTest
@testable import CaptureKit

final class PendingCaptureStoreTests: XCTestCase {
    func testCaptureSurvivesRelaunchUntilExplicitlyCleared() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Images"), withIntermediateDirectories: true)
        let location = directory.appendingPathComponent("state/pending.json")
        try PendingCaptureStore(url: location).save(folder: folder)

        let relaunched = PendingCaptureStore(url: location)
        XCTAssertEqual(relaunched.load(), folder)
        try relaunched.clear()
        XCTAssertNil(PendingCaptureStore(url: location).load())
        try relaunched.clear()
    }

    func testDeletedCaptureIsNotRestored() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingCaptureStore(url: directory.appendingPathComponent("pending.json"))
        try store.save(folder: directory.appendingPathComponent("missing-capture"))
        XCTAssertNil(store.load())
    }
}
