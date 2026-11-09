import Foundation

/// Remembers open uploads so a relaunch resumes instead of restarting.
public protocol UploadStore {
    func uploadId(for key: String) -> String?
    func save(uploadId: String, for key: String)
    func remove(key: String)
}

public final class InMemoryUploadStore: UploadStore {
    private var ids: [String: String] = [:]
    public init() {}
    public func uploadId(for key: String) -> String? { ids[key] }
    public func save(uploadId: String, for key: String) { ids[key] = uploadId }
    public func remove(key: String) { ids[key] = nil }
}

public struct ResumableUploader {
    public var chunkSize = 4 * 1024 * 1024   // the API caps chunks at 8 MiB
    public var maxRetries = 5
    public var sleep: (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }

    let api: APIClient
    let store: UploadStore

    public init(api: APIClient, store: UploadStore) {
        self.api = api
        self.store = store
    }

    /// Uploads one file and returns the stored artifact. Safe to call again after a crash.
    public func upload(
        file: URL, jobId: String, kind: String, onProgress: (Int, Int) -> Void = { _, _ in }
    ) async throws -> Artifact {
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        let sha = try Hashing.sha256(of: file)
        let key = "\(jobId)/\(sha)"

        var upload = try await resumeOrCreate(file: file, jobId: jobId, kind: kind, size: size,
                                              sha: sha, key: key)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var failures = 0
        while upload.offset < size {
            try handle.seek(toOffset: UInt64(upload.offset))
            let chunk = try handle.read(upToCount: min(chunkSize, size - upload.offset)) ?? Data()
            do {
                upload = try await api.appendChunk(uploadId: upload.id, offset: upload.offset, data: chunk)
                failures = 0
                onProgress(upload.offset, size)
            } catch {
                // The response may have been lost after the server applied the chunk, and a
                // 409 means our offset is stale. Either way the server's offset is the truth.
                failures += 1
                if failures > maxRetries { throw error }
                await sleep(min(30, pow(2, Double(failures - 1)) * 0.5))
                upload = try await api.getUpload(upload.id)
            }
        }
        var attempt = 0
        while true {
            do {
                let artifact = try await api.complete(uploadId: upload.id)
                store.remove(key: key)
                return artifact
            } catch {
                // The server may have finished while the reply was lost (network error, or a
                // 409 on the retry). If it did, return what it stored instead of failing.
                if let remote = try? await api.getUpload(upload.id), remote.status == "complete",
                    let done = try await api.listArtifacts(jobId: jobId).first(where: { $0.sha256 == sha })
                {
                    store.remove(key: key)
                    return done
                }
                attempt += 1
                if attempt > maxRetries { throw error }
                await sleep(min(30, pow(2, Double(attempt - 1)) * 0.5))
            }
        }
    }

    private func resumeOrCreate(
        file: URL, jobId: String, kind: String, size: Int, sha: String, key: String
    ) async throws -> Upload {
        if let id = store.uploadId(for: key),
            let existing = try? await api.getUpload(id),
            existing.status == "open", existing.size == size
        {
            return existing
        }
        let created = try await api.createUpload(
            jobId: jobId, filename: file.lastPathComponent, size: size, kind: kind, sha256: sha)
        store.save(uploadId: created.id, for: key)
        return created
    }
}
