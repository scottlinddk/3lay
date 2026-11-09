import Foundation

public struct SubmissionResult: Equatable {
    public let jobId: String
    public let taskId: String
    public let photoCount: Int
}

/// Turns a finished capture folder into a job: uploads photos and manifest, then queues the
/// Mac reconstruction. Re-running after a failure resumes uploads rather than duplicating them.
public struct Submission {
    public static let minimumPhotos = 20

    let api: APIClient
    let uploader: ResumableUploader

    public init(api: APIClient, uploader: ResumableUploader) {
        self.api = api
        self.uploader = uploader
    }

    public func submit(
        name: String, imagesDirectory: URL, device: CaptureManifest.Device, detail: String = "full",
        jobId existingJob: String? = nil, onProgress: (Int, Int) -> Void = { _, _ in }
    ) async throws -> SubmissionResult {
        let (manifest, manifestURL) = try BundleWriter.write(
            imagesDirectory: imagesDirectory, device: device)
        let job: String
        if let existingJob { job = existingJob } else {
            job = try await api.createJob(name: name, sourceKind: "photos").id
        }
        var photos: [[String: String]] = []
        let total = manifest.images.count + 1
        for (i, file) in manifest.images.enumerated() {
            let artifact = try await uploader.upload(
                file: imagesDirectory.appendingPathComponent(file.path), jobId: job, kind: "photo")
            photos.append(["artifact_id": artifact.id, "filename": file.path])
            onProgress(i + 1, total)
        }
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
