#if os(iOS)
import CaptureKit
import Foundation

/// Persists open upload ids across launches so an interrupted submit resumes.
final class FileUploadStore: UploadStore {
    private let url: URL
    private var ids: [String: String]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("uploads.json")
        ids = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    func uploadId(for key: String) -> String? { ids[key] }
    func save(uploadId: String, for key: String) { ids[key] = uploadId; persist() }
    func remove(key: String) { ids[key] = nil; persist() }

    private func persist() {
        try? JSONEncoder().encode(ids).write(to: url, options: .atomic)
    }
}
#endif
