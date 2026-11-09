import Foundation

/// Keeps the most recent unsent capture reachable after a failure or app restart.
public struct PendingCaptureStore {
    private let url: URL

    public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("pending-capture.json")) {
        self.url = url
    }

    public func save(folder: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(folder).write(to: url, options: .atomic)
    }

    public func load() -> URL? {
        guard let data = try? Data(contentsOf: url),
              let folder = try? JSONDecoder().decode(URL.self, from: data),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("Images").path)
        else { return nil }
        return folder
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
