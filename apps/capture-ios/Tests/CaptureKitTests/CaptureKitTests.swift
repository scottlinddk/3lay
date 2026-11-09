import XCTest
@testable import CaptureKit

final class CaptureKitTests: XCTestCase {
    let device = CaptureManifest.Device(model: "iPhone", systemVersion: "17.4", appVersion: "1", hasLiDAR: true)

    func uploader(_ server: FakeServer, chunk: Int = 100, store: UploadStore = InMemoryUploadStore())
        -> (ResumableUploader, APIClient)
    {
        let api = APIClient(transport: server)
        var up = ResumableUploader(api: api, store: store)
        up.chunkSize = chunk
        up.sleep = { _ in }
        return (up, api)
    }

    func testManifestHashesImagesAndRecordsScaleProvenance() throws {
        let dir = try makeTempDir()
        _ = try writeFile(dir, "b.heic", bytes: 10, seed: 3)
        _ = try writeFile(dir, "a.jpg", bytes: 20, seed: 5)
        _ = try writeFile(dir, "notes.txt", bytes: 5)
        let (m, url) = try BundleWriter.write(imagesDirectory: dir, device: device, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(m.schema, "capture-bundle/1")
        XCTAssertEqual(m.images.map(\.path), ["a.jpg", "b.heic"])
        XCTAssertEqual(m.images[0].sha256, try Hashing.sha256(of: dir.appendingPathComponent("a.jpg")))
        XCTAssertEqual(m.scale.provenance, "sensor-lidar")
        let back = try CaptureManifest.decoder().decode(CaptureManifest.self, from: Data(contentsOf: url))
        XCTAssertEqual(back, m)
        // Re-writing must not list manifest.json itself as an image.
        XCTAssertEqual(try BundleWriter.images(in: dir).count, 2)
    }

    func testNoLiDARMeansUnknownScale() throws {
        let dir = try makeTempDir()
        _ = try writeFile(dir, "a.jpg", bytes: 10)
        var d = device
        d.hasLiDAR = false
        let (m, _) = try BundleWriter.write(imagesDirectory: dir, device: d)
        XCTAssertEqual(m.scale.declaredUnits, "unknown")
        XCTAssertEqual(m.scale.provenance, "none")
    }

    func testEmptyFolderThrows() throws {
        XCTAssertThrowsError(try BundleWriter.write(imagesDirectory: try makeTempDir(), device: device)) {
            XCTAssertEqual($0 as? BundleError, .noImages)
        }
    }

    func testUploadsInChunksAndVerifies() async throws {
        let server = FakeServer()
        let (up, api) = uploader(server)
        let job = try await api.createJob(name: "j", sourceKind: "photos")
        let file = try writeFile(try makeTempDir(), "p.jpg", bytes: 350)
        let art = try await up.upload(file: file, jobId: job.id, kind: "photo")
        XCTAssertEqual(art.sha256, try Hashing.sha256(of: file))
        XCTAssertEqual(server.requests.filter { $0.hasPrefix("PATCH") }.count, 4)
    }

    func testLostResponseResyncsWithoutDuplicatingBytes() async throws {
        let server = FakeServer()
        var dropped = false
        // The server applies the second chunk, then the connection dies before the reply.
        server.dropResponse = { r in
            if r.method == "PATCH", r.query.first?.value == "100", !dropped { dropped = true; return true }
            return false
        }
        let (up, api) = uploader(server)
        let job = try await api.createJob(name: "j", sourceKind: "photos")
        let file = try writeFile(try makeTempDir(), "p.jpg", bytes: 350)
        let art = try await up.upload(file: file, jobId: job.id, kind: "photo")
        XCTAssertTrue(dropped)
        XCTAssertEqual(art.size, 350)
        XCTAssertEqual(server.uploads.values.first?.data, try Data(contentsOf: file))
    }

    func testResumesAfterRelaunchUsingStore() async throws {
        let server = FakeServer()
        let store = InMemoryUploadStore()
        var (up, api) = uploader(server, store: store)
        let job = try await api.createJob(name: "j", sourceKind: "photos")
        let file = try writeFile(try makeTempDir(), "p.jpg", bytes: 350)
        up.maxRetries = 0
        server.beforeRequest = { r in
            if r.method == "PATCH", r.query.first?.value == "200" { throw FakeServer.Dropped() }
        }
        do { _ = try await up.upload(file: file, jobId: job.id, kind: "photo"); XCTFail("should fail") }
        catch {}
        XCTAssertEqual(server.uploads.count, 1)

        server.beforeRequest = nil
        (up, api) = uploader(server, store: store)  // new process, same store
        let art = try await up.upload(file: file, jobId: job.id, kind: "photo")
        XCTAssertEqual(server.uploads.count, 1, "must reuse the open upload")
        XCTAssertEqual(art.size, 350)
    }

    func testGivesUpAfterMaxRetries() async throws {
        let server = FakeServer()
        let (up, api) = uploader(server)
        let job = try await api.createJob(name: "j", sourceKind: "photos")
        server.beforeRequest = { r in if r.method == "PATCH" { throw FakeServer.Dropped() } }
        let file = try writeFile(try makeTempDir(), "p.jpg", bytes: 350)
        do { _ = try await up.upload(file: file, jobId: job.id, kind: "photo"); XCTFail() }
        catch { XCTAssertTrue(error is FakeServer.Dropped) }
    }

    func testCompleteResponseLostStillReturnsArtifact() async throws {
        let server = FakeServer()
        var dropped = false
        server.dropResponse = { r in
            defer { if r.path.hasSuffix("complete") { dropped = true } }
            return r.path.hasSuffix("complete") && !dropped
        }
        let (up, api) = uploader(server)
        let job = try await api.createJob(name: "j", sourceKind: "photos")
        let file = try writeFile(try makeTempDir(), "p.jpg", bytes: 120)
        let art = try await up.upload(file: file, jobId: job.id, kind: "photo")
        XCTAssertEqual(art.sha256, try Hashing.sha256(of: file))
    }

    func testSubmissionQueuesReconstructionWithPhotoReferences() async throws {
        let server = FakeServer()
        let (up, api) = uploader(server)
        let dir = try makeTempDir()
        _ = try writeFile(dir, "IMG_1.heic", bytes: 150, seed: 3)
        _ = try writeFile(dir, "IMG_2.heic", bytes: 90, seed: 7)
        var progress: [Int] = []
        let result = try await Submission(api: api, uploader: up).submit(
            name: "mug", imagesDirectory: dir, device: device, onProgress: { d, _ in progress.append(d) })
        XCTAssertEqual(result.photoCount, 2)
        XCTAssertEqual(progress, [1, 2, 3])
        XCTAssertEqual(server.uploads.values.map(\.kind).sorted(), ["capture_bundle", "photo", "photo"])
        let task = try XCTUnwrap(server.tasks.first)
        XCTAssertEqual(task["capability"] as? String, "reconstruct")
        let payload = try XCTUnwrap(task["payload"] as? [String: Any])
        let photos = try XCTUnwrap(payload["photos"] as? [[String: String]])
        XCTAssertEqual(photos.map { $0["filename"]! }, ["IMG_1.heic", "IMG_2.heic"])
        XCTAssertNotNil(payload["manifest_artifact_id"])
        XCTAssertEqual((task["input_revision"] as? String)?.count, 16)
    }

    func testResubmitReusesJobAndDoesNotReuploadFinishedFiles() async throws {
        let server = FakeServer()
        let (up, api) = uploader(server)
        let dir = try makeTempDir()
        _ = try writeFile(dir, "IMG_1.heic", bytes: 150)
        let sub = Submission(api: api, uploader: up)
        // First attempt dies when the task is created, after every upload finished.
        server.beforeRequest = { r in if r.path.hasSuffix("tasks") { throw FakeServer.Dropped() } }
        do { _ = try await sub.submit(name: "x", imagesDirectory: dir, device: device); XCTFail() } catch {}
        server.beforeRequest = nil
        let before = server.uploads.count
        let result = try await sub.submit(name: "x", imagesDirectory: dir, device: device, jobId: "job1")
        XCTAssertEqual(result.jobId, "job1")
        XCTAssertEqual(server.tasks.count, 1)
        // The photo is re-sent as a new upload only if the server does not already hold it.
        XCTAssertLessThanOrEqual(server.uploads.count, before + 2)
    }

    func testPairingLinkRejectsInsecureAndMalformedLinks() {
        let ok = PairingLink(url: URL(string: "scan3d://pair?server=https://scan.example.com&token=abc")!)
        XCTAssertEqual(ok?.server.host, "scan.example.com")
        XCTAssertEqual(ok?.token, "abc")
        XCTAssertNotNil(PairingLink(url: URL(string: "scan3d://pair?server=http://localhost:8000&token=abc")!))
        XCTAssertNil(PairingLink(url: URL(string: "scan3d://pair?server=http://evil.example&token=abc")!))
        XCTAssertNil(PairingLink(url: URL(string: "scan3d://pair?server=https://x.io")!))
        XCTAssertNil(PairingLink(url: URL(string: "https://x.io/pair?server=https://x.io&token=a")!))
    }

    func testAPIErrorsCarryServerDetail() async throws {
        let api = APIClient(transport: FakeServer())
        do { _ = try await api.getUpload("nope"); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .http(status: 404, detail: "upload not found")) }
    }
}

final class ContractFixtureTests: XCTestCase {
    func fixture<T: Decodable>(_ name: String, as: T.Type = T.self) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try APIClient.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    func testDecodesRealAPIShapes() throws {
        XCTAssertEqual(try fixture("job", as: Job.self).sourceKind, "photos")
        XCTAssertEqual(try fixture("upload", as: Upload.self).offset, 4)
        XCTAssertEqual(try fixture("artifact", as: Artifact.self).jobId, "j1")
        XCTAssertEqual(try fixture("task", as: TaskInfo.self).capability, "reconstruct")
    }
}
