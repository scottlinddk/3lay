import Foundation
@testable import CaptureKit

/// In-memory stand-in for the API's job, upload and task endpoints, with the same offset rules.
final class FakeServer: HTTPTransport {
    struct StoredUpload { var id: String; var jobId: String; var filename: String; var kind: String
        var size: Int; var sha: String?; var data = Data(); var complete = false }

    var uploads: [String: StoredUpload] = [:]
    var artifacts: [[String: Any]] = []
    var tasks: [[String: Any]] = []
    var jobs = 0
    var requests: [String] = []
    /// Called before each request; throw to simulate a dropped connection.
    var beforeRequest: ((HTTPRequest) throws -> Void)?
    /// Called after the server applied a request but before the client sees the response.
    var dropResponse: ((HTTPRequest) -> Bool)?

    struct Dropped: Error {}

    func send(_ r: HTTPRequest) async throws -> HTTPResponse {
        requests.append("\(r.method) \(r.path)")
        try beforeRequest?(r)
        let res = handle(r)
        if dropResponse?(r) == true { throw Dropped() }
        return res
    }

    private func json(_ status: Int, _ object: Any) -> HTTPResponse {
        HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
    }

    private func uploadJSON(_ u: StoredUpload) -> [String: Any] {
        ["id": u.id, "job_id": u.jobId, "filename": u.filename, "size": u.size, "offset": u.data.count,
         "status": u.complete ? "complete" : "open"]
    }

    private func handle(_ r: HTTPRequest) -> HTTPResponse {
        let parts = r.path.split(separator: "/").map(String.init)
        let body = r.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let n = parts.count
        if r.method == "POST", parts == ["api", "jobs"] {
            jobs += 1
            return json(201, ["id": "job\(jobs)", "name": body["name"] ?? "", "source_kind": "photos",
                              "status": "created"])
        }
        if r.method == "POST", n == 4, parts[0] == "api", parts[1] == "jobs", parts[3] == "uploads" {
            let job = parts[2]
            let id = "up\(uploads.count + 1)"
            let u = StoredUpload(id: id, jobId: job, filename: body["filename"] as! String,
                                 kind: body["kind"] as! String, size: body["size"] as! Int,
                                 sha: body["sha256"] as? String)
            uploads[id] = u
            return json(201, uploadJSON(u))
        }
        if r.method == "GET", n == 3, parts[1] == "uploads" {
            let id = parts[2]
            guard let u = uploads[id] else { return json(404, ["detail": "upload not found"]) }
            return json(200, uploadJSON(u))
        }
        if r.method == "PATCH", n == 3, parts[1] == "uploads" {
            let id = parts[2]
            guard var u = uploads[id] else { return json(404, ["detail": "upload not found"]) }
            let offset = Int(r.query.first { $0.name == "offset" }!.value!)!
            guard offset == u.data.count else {
                return json(409, ["detail": "offset mismatch, server has \(u.data.count)"])
            }
            u.data.append(r.body ?? Data())
            uploads[id] = u
            return json(200, uploadJSON(u))
        }
        if r.method == "POST", n == 4, parts[1] == "uploads", parts[3] == "complete" {
            let id = parts[2]
            guard var u = uploads[id] else { return json(404, ["detail": "upload not found"]) }
            if u.complete { return json(409, ["detail": "upload already complete"]) }
            if u.data.count != u.size { return json(409, ["detail": "incomplete"]) }
            if let sha = u.sha, sha != Hashing.sha256(of: u.data) { return json(422, ["detail": "sha256 mismatch"]) }
            u.complete = true
            uploads[id] = u
            let art: [String: Any] = ["id": "art-\(id)", "job_id": u.jobId, "kind": u.kind,
                                      "filename": u.filename, "size": u.size,
                                      "sha256": Hashing.sha256(of: u.data), "protected": true]
            artifacts.append(art)
            return json(200, art)
        }
        if r.method == "GET", n == 4, parts[1] == "jobs", parts[3] == "artifacts" {
            let job = parts[2]
            return json(200, artifacts.filter { $0["job_id"] as? String == job })
        }
        if r.method == "POST", n == 4, parts[1] == "jobs", parts[3] == "tasks" {
            let job = parts[2]
            var t = body
            t["id"] = "task\(tasks.count + 1)"
            t["job_id"] = job
            t["state"] = "queued"
            tasks.append(t)
            return json(201, t)
        }
        return json(404, ["detail": "no route"])
    }
}

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func writeFile(_ dir: URL, _ name: String, bytes: Int, seed: UInt8 = 1) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* Int(seed) &+ Int(seed)) }).write(to: url)
    return url
}
