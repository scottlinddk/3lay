import XCTest
@testable import CaptureKit

final class ScanQualityTests: XCTestCase {
    func testOldObjectCaptureDoesNotInventCoverageOrDefects() {
        let snapshot = ScanQualitySnapshot(mode: .object, photoCount: 80)
        XCTAssertTrue(snapshot.evidence.isEmpty)
        XCTAssertNil(snapshot.observedCoverage)
        XCTAssertTrue(snapshot.summary.contains("not measured"))
    }

    func testObservedCoverageNeverMeansWholeObjectCompleteness() {
        let snapshot = ScanQualitySnapshot(mode: .lidar, photoCount: 100, observedCoverage: 100)
        XCTAssertTrue(snapshot.summary.contains("Unseen surfaces are not measured"))
        XCTAssertFalse(snapshot.evidence.contains { $0.action == .coverObservedSurfaces })
        let unknown = ScanQualitySnapshot(mode: .lidar, photoCount: 5)
        XCTAssertNil(unknown.observedCoverage)
        XCTAssertFalse(unknown.evidence.contains { $0.id == "coverage" })
        XCTAssertNil(ScanQualitySnapshot(mode: .object, photoCount: 5, observedCoverage: 90).observedCoverage)
    }

    func testFirstRejectionRatesAndSmallSampleDoNotOverstateDefects() {
        var measurements = ScanQualityAccumulator()
        for _ in 0..<3 { measurements.record(.skip(.longExposure)) }
        var snapshot = measurements.snapshot(photoCount: 1, coverage: nil, plateau: false, thermal: "nominal")
        XCTAssertFalse(snapshot.evidence.contains { $0.action == .addLight })
        for _ in 0..<17 { measurements.record(.take) }
        snapshot = measurements.snapshot(photoCount: 17, coverage: 42, plateau: true, thermal: "nominal")
        XCTAssertEqual(snapshot.sampledFrames, 20)
        XCTAssertEqual(snapshot.darkFrames, 3)
        XCTAssertTrue(snapshot.evidence.contains { $0.action == .addLight })
        XCTAssertTrue(snapshot.evidence.contains { $0.action == .changeViewpoint })
        XCTAssertEqual(snapshot.blurryFrames, 0)
    }

    func testUnsupportedOrContradictoryAdviceFallsBackAsAWhole() {
        let snapshot = ScanQualitySnapshot(mode: .object, photoCount: 10, feedback: ["dark"])
        for selections in [
            [ScanAdviceSelection(action: .addLight, evidenceID: "invented")],
            [.init(action: .moveCloser, evidenceID: "exposure")],
            [.init(action: .addLight, evidenceID: "exposure"), .init(action: .addLight, evidenceID: "exposure")],
            []
        ] {
            let report = ScanQualityReport(snapshot: snapshot, selections: selections)
            XCTAssertEqual(report.source, "measured")
            XCTAssertEqual(report.suggestions, Array(snapshot.evidence.prefix(3)))
        }
    }

    func testAIReordersOnlySupportedActionsAndCannotSuppressHeat() {
        var snapshot = ScanQualitySnapshot(mode: .object, photoCount: 10, feedback: ["dark"])
        var report = ScanQualityReport(snapshot: snapshot, selections: [.init(action: .morePhotos, evidenceID: "photo-count")])
        XCTAssertEqual(report.source, "onDevice")
        XCTAssertEqual(report.suggestions.first?.action, .morePhotos)
        snapshot.thermal = "critical"
        report = ScanQualityReport(snapshot: snapshot, selections: [.init(action: .morePhotos, evidenceID: "photo-count")])
        XCTAssertEqual(report.source, "measured")
        XCTAssertEqual(report.suggestions.first?.action, .coolDown)
    }

    func testMetadataRoundTripsWithoutChangingOriginalPhotosOrRecreatingDeletedScan() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = Data([1, 2, 3, 4])
        let photo = folder.appendingPathComponent("original.jpg")
        try original.write(to: photo)
        let snapshot = ScanQualitySnapshot(mode: .lidar, photoCount: 60, observedCoverage: 75)
        try ScanQualityFiles.save(snapshot, named: ScanQualityFiles.snapshotName, folder: folder)
        XCTAssertEqual(ScanQualityFiles.loadSnapshot(folder: folder), snapshot)
        XCTAssertEqual(try Data(contentsOf: photo), original)
        try FileManager.default.removeItem(at: folder)
        try ScanQualityFiles.save(snapshot, named: ScanQualityFiles.snapshotName, folder: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testPhotoSelectionExcludesMetadataDirectoriesAndSymbolicLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let images = folder.appendingPathComponent("Images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["0002.HEIC", "0001.jpg", "metadata.json", "depth.bin"] {
            try Data([1]).write(to: images.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: images.appendingPathComponent("directory.jpg"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: images.appendingPathComponent("linked.jpg"),
                                                  withDestinationURL: images.appendingPathComponent("0001.jpg"))
        XCTAssertEqual(ScanQualityFiles.photoURLs(folder: folder, mode: .object).map(\.lastPathComponent), ["0001.jpg", "0002.HEIC"])
    }

    func testRepresentativePhotosAreBoundedAndDistinct() {
        XCTAssertEqual(ScanQualityFiles.representativeIndices(count: 0), [])
        XCTAssertEqual(ScanQualityFiles.representativeIndices(count: 1), [0])
        XCTAssertEqual(ScanQualityFiles.representativeIndices(count: 2), [0, 1])
        XCTAssertEqual(ScanQualityFiles.representativeIndices(count: 400), [0, 200, 399])
    }

    func testEvaluationFixtures() throws {
        struct Fixture: Decodable { var name: String; var snapshot: ScanQualitySnapshot; var expected: [ScanAdviceAction] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "scan-coach-cases", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        for fixture in fixtures {
            XCTAssertEqual(ScanQualityReport(snapshot: fixture.snapshot).suggestions.map(\.action), fixture.expected, fixture.name)
        }
    }
}

final class ScanAdviceRunnerTests: XCTestCase {
    func testTimeoutReleasesSlotAndNextRequestSucceeds() async throws {
        let runner = ScanAdviceRunner()
        do {
            _ = try await runner.run(timeout: .milliseconds(10)) {
                try await Task.sleep(for: .seconds(30)); return 1
            }
            XCTFail("Expected timeout")
        } catch ScanAdviceRunner.Failure.timeout {} catch { XCTFail("Unexpected error: \(error)") }
        let result = try await runner.run { 2 }
        XCTAssertEqual(result, 2)
    }

    func testOnlyOneRequestRunsAndCancellationPropagates() async throws {
        let runner = ScanAdviceRunner()
        let started = expectation(description: "provider started")
        let task = Task {
            try await runner.run {
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 2)
        do { _ = try await runner.run { 2 }; XCTFail("Concurrent provider ran") }
        catch ScanAdviceRunner.Failure.busy {} catch { XCTFail("Unexpected error: \(error)") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled result escaped") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let result = try await runner.run { 3 }
        XCTAssertEqual(result, 3)
    }

    func testReconstructionCancelsInferenceAndBlocksNewRequestsUntilFinished() async throws {
        let runner = ScanAdviceRunner()
        let started = expectation(description: "inference started")
        let task = Task {
            try await runner.run {
                started.fulfill()
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 2)
        try await runner.withSuspended {
            do { _ = try await runner.run { 2 }; XCTFail("Inference ran during reconstruction") }
            catch ScanAdviceRunner.Failure.suspended {} catch { XCTFail("Unexpected error: \(error)") }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let result = try await runner.run { 3 }
        XCTAssertEqual(result, 3)
    }

    func testProviderFailureDoesNotPoisonLaterRequests() async throws {
        enum Refusal: Error { case refused }
        let runner = ScanAdviceRunner()
        do { let _: Int = try await runner.run { throw Refusal.refused }; XCTFail("Expected refusal") }
        catch Refusal.refused {}
        let result = try await runner.run { 4 }
        XCTAssertEqual(result, 4)
    }
}
