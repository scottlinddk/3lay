import Foundation

public enum APIError: Error, Equatable {
    case http(status: Int, detail: String)
    case decoding(String)
}

public struct Job: Codable, Equatable {
    public var id: String
    public var name: String
    public var sourceKind: String
    public var status: String
}

public struct Upload: Codable, Equatable {
    public var id: String
    public var jobId: String
    public var filename: String
    public var size: Int
    public var offset: Int
    public var status: String
}

public struct Artifact: Codable, Equatable {
    public var id: String
    public var jobId: String
    public var kind: String
    public var filename: String
    public var size: Int
    public var sha256: String
}

public struct TaskInfo: Codable, Equatable {
    public var id: String
    public var jobId: String
    public var capability: String
    public var state: String
}

/// Mirrors the FastAPI contract in apps/web/openapi.json (snake_case on the wire).
public struct APIClient {
    let transport: HTTPTransport

    public init(transport: HTTPTransport) { self.transport = transport }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func call<T: Decodable>(_ req: HTTPRequest, as: T.Type = T.self) async throws -> T {
        let res = try await transport.send(req)
        guard (200..<300).contains(res.status) else {
            let detail = (try? JSONSerialization.jsonObject(with: res.body) as? [String: Any])?["detail"]
            throw APIError.http(status: res.status, detail: detail.map { "\($0)" } ?? "")
        }
        do { return try APIClient.decoder.decode(T.self, from: res.body) } catch {
            throw APIError.decoding("\(error)")
        }
    }

    private func json(_ object: [String: Any]) -> (Data, [String: String]) {
        (try! JSONSerialization.data(withJSONObject: object), ["Content-Type": "application/json"])
    }

    public func createJob(name: String, sourceKind: String) async throws -> Job {
        let (body, headers) = json(["name": name, "source_kind": sourceKind])
        return try await call(HTTPRequest(method: "POST", path: "api/jobs", headers: headers, body: body))
    }

    public func createUpload(
        jobId: String, filename: String, size: Int, kind: String, sha256: String?
    ) async throws -> Upload {
        var obj: [String: Any] = ["filename": filename, "size": size, "kind": kind]
        if let sha256 { obj["sha256"] = sha256 }
        let (body, headers) = json(obj)
        return try await call(
            HTTPRequest(method: "POST", path: "api/jobs/\(jobId)/uploads", headers: headers, body: body))
    }

    public func getUpload(_ id: String) async throws -> Upload {
        try await call(HTTPRequest(method: "GET", path: "api/uploads/\(id)"))
    }

    public func appendChunk(uploadId: String, offset: Int, data: Data) async throws -> Upload {
        try await call(
            HTTPRequest(
                method: "PATCH", path: "api/uploads/\(uploadId)",
                query: [URLQueryItem(name: "offset", value: String(offset))],
                headers: ["Content-Type": "application/octet-stream"], body: data))
    }

    public func complete(uploadId: String) async throws -> Artifact {
        try await call(HTTPRequest(method: "POST", path: "api/uploads/\(uploadId)/complete"))
    }

    public func listArtifacts(jobId: String) async throws -> [Artifact] {
        try await call(HTTPRequest(method: "GET", path: "api/jobs/\(jobId)/artifacts"))
    }

    public func createTask(
        jobId: String, capability: String, inputRevision: String, payload: [String: Any]
    ) async throws -> TaskInfo {
        let (body, headers) = json(
            ["capability": capability, "input_revision": inputRevision, "payload": payload])
        return try await call(
            HTTPRequest(method: "POST", path: "api/jobs/\(jobId)/tasks", headers: headers, body: body))
    }
}
