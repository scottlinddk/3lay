import Foundation

public struct SubmissionResult: Equatable {
    public let jobId: String
    public let taskId: String
    public let photoCount: Int
}

/// Turns a finished capture folder into a job: uploads photos and manifest, then queues the
/// Mac reconstruction. Re-running after a failure resumes uploads rather than duplicating them.
public struct Submission {
    public static let minimumPhotos = 50
    static let maxConcurrentUploads = 4

    let api: APIClient
    let uploader: ResumableUploader

    public init(api: APIClient, uploader: ResumableUploader) {
        self.api = api
        self.uploader = uploader
    }

    public func submit(
        name: String, imagesDirectory: URL, device: CaptureManifest.Device, detail: String = "full",
        jobId existingJob: String? = nil, onJobCreated: (String) async -> Void = { _ in },
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) async throws -> SubmissionResult {
        let (manifest, manifestURL) = try BundleWriter.write(
            imagesDirectory: imagesDirectory, device: device)
        let job: String
        if let existingJob { job = existingJob } else {
            job = try await api.createJob(name: name, sourceKind: "photos").id
            // Remember it before anything can fail, so a retry continues this job instead of opening another.
            await onJobCreated(job)
        }
        let images = manifest.images
        let total = images.count + 1
        var artifactIds = [String](repeating: "", count: images.count)
        var done = 0
        // A few photos at a time: one at a time left the connection idle between round trips. The
        // manifest already holds each photo's hash, so the uploader does not read the files again.
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var inFlight = 0
            func record(_ result: (Int, String)) {
                artifactIds[result.0] = result.1
                done += 1
                onProgress(done, total)
            }
            for (i, file) in images.enumerated() {
                if inFlight >= Self.maxConcurrentUploads, let finished = try await group.next() {
                    record(finished)
                    inFlight -= 1
                }
                group.addTask {
                    let artifact = try await uploader.upload(
                        file: imagesDirectory.appendingPathComponent(file.path), jobId: job,
                        kind: "photo", sha256: file.sha256)
                    return (i, artifact.id)
                }
                inFlight += 1
            }
            while let finished = try await group.next() { record(finished) }
        }
        let photos = zip(images, artifactIds).map { ["artifact_id": $1, "filename": $0.path] }
        let manifestArtifact = try await uploader.upload(
            file: manifestURL, jobId: job, kind: "capture_bundle")
        onProgress(total, total)

        // The manifest hash names this exact input set, so a changed capture is a new revision.
        let revision = String(try Hashing.sha256(of: manifestURL).prefix(16))
        let task = try await api.createTask(
            jobId: job, capability: "reconstruct", inputRevision: revision,
            payload: ["photos": photos, "detail": detail, "manifest_artifact_id": manifestArtifact.id])
        return SubmissionResult(jobId: job, taskId: task.id, photoCount: photos.count)
    }
}
