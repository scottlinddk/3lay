import CryptoKit
import XCTest
@testable import ScanLinkCore

final class LanTransferTests: XCTestCase {
    private var root: URL!
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func store(expiry: TimeInterval = 3600) -> LanTransferStore {
        LanTransferStore(
            directory: root.appendingPathComponent("transfers"), inbox: root.appendingPathComponent("inbox"),
            expiry: expiry, now: { self.clock })
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testChunksAssembleAndCompleteOnce() throws {
        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        let id = UUID().uuidString
        let s = store()
        XCTAssertEqual(try s.begin(id: id, name: "a.usdz", size: payload.count, sha256: sha(payload)).offset, 0)
        let first = try s.append(id: id, offset: 0, data: payload.prefix(4000))
        XCTAssertNil(first.completed)
        XCTAssertEqual(first.info.offset, 4000)
        let last = try s.append(id: id, offset: 4000, data: payload.dropFirst(4000))
        let file = try XCTUnwrap(last.completed)
        XCTAssertTrue(last.info.complete)
        XCTAssertEqual(try Data(contentsOf: file), payload)
        // A duplicate completion is refused and does not import a second copy.
        XCTAssertThrowsError(try s.append(id: id, offset: 4000, data: payload.dropFirst(4000))) {
            XCTAssertEqual($0 as? LanTransferError, .offsetMismatch(current: payload.count))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("inbox").path).count, 1)
    }

    func testResumeAfterRestartAndRepeatedBegin() throws {
        let payload = Data(repeating: 7, count: 5000)
        let id = UUID().uuidString
        _ = try store().begin(id: id, name: "a.usdz", size: 5000, sha256: sha(payload))
        _ = try store().append(id: id, offset: 0, data: payload.prefix(2000))
        // A new store instance (app restart) and a repeated begin report where the transfer stands.
        let again = try store().begin(id: id, name: "a.usdz", size: 5000, sha256: sha(payload))
        XCTAssertEqual(again.offset, 2000)
        XCTAssertThrowsError(try store().begin(id: id, name: "a.usdz", size: 4999, sha256: sha(payload))) {
            XCTAssertEqual($0 as? LanTransferError, .conflict)
        }
    }

    func testWrongOffsetIsRefusedWithTheCurrentOne() throws {
        let id = UUID().uuidString
        let s = store()
        _ = try s.begin(id: id, name: "a.usdz", size: 100, sha256: sha(Data(count: 100)))
        _ = try s.append(id: id, offset: 0, data: Data(count: 40))
        XCTAssertThrowsError(try s.append(id: id, offset: 10, data: Data(count: 10))) {
            XCTAssertEqual($0 as? LanTransferError, .offsetMismatch(current: 40))
        }
        XCTAssertEqual(try s.info(id: id).offset, 40)
    }

    func testCorruptFileIsNotImportedAndRestarts() throws {
        let id = UUID().uuidString
        let s = store()
        _ = try s.begin(id: id, name: "a.usdz", size: 10, sha256: sha(Data(repeating: 1, count: 10)))
        XCTAssertThrowsError(try s.append(id: id, offset: 0, data: Data(repeating: 2, count: 10))) {
            XCTAssertEqual($0 as? LanTransferError, .checksumMismatch)
        }
        XCTAssertEqual(try s.info(id: id).offset, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox").path))
    }

    func testRejectsPathTraversalBadNamesAndOversize() {
        let s = store()
        XCTAssertThrowsError(try s.begin(id: "../../etc/passwd", name: "a.usdz", size: 1, sha256: "x")) {
            XCTAssertEqual($0 as? LanTransferError, .invalidID)
        }
        XCTAssertThrowsError(try s.begin(id: UUID().uuidString, name: "a.exe", size: 1, sha256: "x")) {
            XCTAssertEqual($0 as? LanTransferError, .unsupportedName)
        }
        XCTAssertThrowsError(try s.begin(id: UUID().uuidString, name: "a.usdz", size: LanProtocol.maxUploadBytes + 1, sha256: "x"))
    }

    func testExpiryRemovesStaleTransfers() throws {
        let id = UUID().uuidString
        let s = store(expiry: 60)
        _ = try s.begin(id: id, name: "a.usdz", size: 10, sha256: "x")
        XCTAssertEqual(s.expire(), 0)
        clock = clock.addingTimeInterval(120)
        XCTAssertEqual(s.expire(), 1)
        XCTAssertThrowsError(try s.info(id: id)) { XCTAssertEqual($0 as? LanTransferError, .unknown) }
    }
}
