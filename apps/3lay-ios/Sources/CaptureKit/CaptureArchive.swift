import Foundation

public enum CaptureArchiveError: Error, LocalizedError {
    case noPhotos
    case zipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noPhotos: return "There are no photos to send."
        case .zipFailed(let why): return "Could not pack the photos: \(why)"
        }
    }
}

/// Packs a capture's photos into one zip for the Mac. Uses the system's own zipping
/// (`NSFileCoordinator.forUploading`), so there is no zip library to ship.
public enum CaptureArchive {
    /// Returns a zip in the temporary directory named `name`.zip. It holds the photos folder, so
    /// the Mac finds them under one top-level folder. The caller deletes it when done.
    public static func make(imagesDirectory: URL, name: String) throws -> URL {
        let photos = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        guard !photos.isEmpty else { throw CaptureArchiveError.noPhotos }
        var coordinationError: NSError?
        var result: Result<URL, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: imagesDirectory, options: .forUploading, error: &coordinationError
        ) { zipped in
            // The coordinator deletes `zipped` when this block returns, so copy it out first.
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).zip")
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipped, to: destination)
                result = .success(destination)
            } catch { result = .failure(error) }
        }
        if let coordinationError { throw CaptureArchiveError.zipFailed(coordinationError.localizedDescription) }
        switch result {
        case .success(let url): return url
        case .failure(let error): throw CaptureArchiveError.zipFailed(error.localizedDescription)
        case nil: throw CaptureArchiveError.zipFailed("no archive was produced")
        }
    }
}
