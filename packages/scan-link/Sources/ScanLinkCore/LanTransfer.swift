import CryptoKit
import Foundation

/// Resumable upload protocol (additive: the whole-file `PUT /upload/<name>` still works).
///
///     POST  /transfers/<id>?name=&size=&sha256=   create, or return the existing transfer (idempotent)
///     GET   /transfers/<id>                       current state
///     PATCH /transfers/<id>   Upload-Offset: N    append one chunk at offset N
///
/// `<id>` is a UUID chosen by the phone and kept with the scan, so a relaunch resumes the same transfer.
/// The receiver's byte count on disk is the truth: a client that lost a response asks again.
public struct LanTransferInfo: Codable, Equatable {
    public var id: String
    public var name: String
    public var size: Int
    public var sha256: String
    /// Bytes the receiver holds. Equals `size` once complete.
    public var offset: Int
    public var complete: Bool
}

public enum LanTransferError: Error, Equatable, LocalizedError {
    case invalidID
    case unsupportedName
    case tooLarge(maxBytes: Int)
    case unknown
    /// The id exists with different name/size/checksum.
    case conflict
    /// The chunk does not start where the receiver is. `current` is where it should.
    case offsetMismatch(current: Int)
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidID: return "The transfer id is not valid."
        case .unsupportedName: return "The Mac only accepts STL, OBJ, PLY, USDZ or a zip of photos."
        case .tooLarge(let max): return "The file is larger than the Mac's \(max / 1_000_000) MB limit."
        case .unknown: return "The Mac no longer has this transfer. It starts again."
        case .conflict: return "A different file already uses this transfer."
        case .offsetMismatch: return "The Mac and phone disagree about progress. Resyncing."
        case .checksumMismatch: return "The file arrived damaged. It will be sent again."
        }
    }
}

/// Receiver-side state of resumable uploads. Foundation only, no sockets, so it is unit tested.
/// Each transfer is `<id>.json` (name, size, checksum, created) plus `<id>.part` (bytes so far);
/// the part file's length is the offset, so nothing is lost if the Mac app restarts.
/// Call from one queue at a time per transfer; the store serialises access with a lock.
public final class LanTransferStore {
    private struct Meta: Codable {
        var name: String
        var size: Int
        var sha256: String
        var createdAt: Date
        /// Set once the file was moved to the inbox, so a duplicate completion is recognised.
        var completedAs: String?
    }

    private let directory: URL
    private let inbox: URL
    private let expiry: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()

    public init(directory: URL, inbox: URL, expiry: TimeInterval = 24 * 3600, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.inbox = inbox
        self.expiry = expiry
        self.now = now
    }

    // MARK: Public

    public func begin(id: String, name: String, size: Int, sha256: String) throws -> LanTransferInfo {
        try lock.withLock {
            try validate(id: id)
            guard LanProtocol.isAcceptedUpload(name) else { throw LanTransferError.unsupportedName }
            let limit = LanProtocol.maxBytes(for: name)
            guard size >= 0, size <= limit else { throw LanTransferError.tooLarge(maxBytes: limit) }
            let sha = sha256.lowercased()
            if let meta = readMeta(id) {
                guard meta.name == name, meta.size == size, meta.sha256 == sha else { throw LanTransferError.conflict }
                return info(id, meta)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: part(id).path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try writeMeta(id, Meta(name: name, size: size, sha256: sha, createdAt: now(), completedAs: nil))
            return LanTransferInfo(id: id, name: name, size: size, sha256: sha, offset: 0, complete: false)
        }
    }

    public func info(id: String) throws -> LanTransferInfo {
        try lock.withLock {
            try validate(id: id)
            guard let meta = readMeta(id) else { throw LanTransferError.unknown }
            return info(id, meta)
        }
    }

    /// Appends `data` at `offset`. Returns the new state and, only on the call that completes the file,
    /// its final location in the inbox (so the app imports it exactly once).
    public func append(id: String, offset: Int, data: Data) throws -> (info: LanTransferInfo, completed: URL?) {
        try lock.withLock {
            try validate(id: id)
            guard var meta = readMeta(id) else { throw LanTransferError.unknown }
            if meta.completedAs != nil { throw LanTransferError.offsetMismatch(current: meta.size) }
            let current = partSize(id)
            guard offset == current else { throw LanTransferError.offsetMismatch(current: current) }
            guard current + data.count <= meta.size else { throw LanTransferError.tooLarge(maxBytes: meta.size) }
            if !data.isEmpty {
                let handle = try FileHandle(forWritingTo: part(id))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
            guard current + data.count == meta.size else { return (info(id, meta), nil) }

            // Complete: verify before it can be imported.
            guard try Self.sha256(of: part(id)) == meta.sha256 else {
                try? FileManager.default.removeItem(at: part(id))
                FileManager.default.createFile(atPath: part(id).path, contents: nil)  // start over
                throw LanTransferError.checksumMismatch
            }
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let destination = inbox.appendingPathComponent("\(UUID().uuidString)-\(meta.name)")
            try FileManager.default.moveItem(at: part(id), to: destination)
            meta.completedAs = destination.lastPathComponent
            try writeMeta(id, meta)
            return (info(id, meta), destination)
        }
    }

    /// Removes transfers older than the expiry. Call at start-up and when a transfer begins.
    @discardableResult
    public func expire() -> Int {
        lock.withLock {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            var removed = 0
            for file in names where file.hasSuffix(".json") {
                let id = String(file.dropLast(5))
                guard let meta = readMeta(id), now().timeIntervalSince(meta.createdAt) > expiry else { continue }
                try? FileManager.default.removeItem(at: part(id))
                try? FileManager.default.removeItem(at: metaURL(id))
                removed += 1
            }
            return removed
        }
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Private

    /// Ids become file names, so only UUIDs are accepted: no path separators, no `..`.
    private func validate(id: String) throws {
        guard UUID(uuidString: id) != nil else { throw LanTransferError.invalidID }
    }

    private func part(_ id: String) -> URL { directory.appendingPathComponent("\(id.lowercased()).part") }
    private func metaURL(_ id: String) -> URL { directory.appendingPathComponent("\(id.lowercased()).json") }

    private func partSize(_ id: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: part(id).path)[.size]) as? Int) ?? 0
    }

    private func readMeta(_ id: String) -> Meta? {
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Meta.self, from: data)
    }

    private func writeMeta(_ id: String, _ meta: Meta) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: metaURL(id), options: .atomic)
    }

    private func info(_ id: String, _ meta: Meta) -> LanTransferInfo {
        let done = meta.completedAs != nil
        return LanTransferInfo(
            id: id.lowercased(), name: meta.name, size: meta.size, sha256: meta.sha256,
            offset: done ? meta.size : partSize(id), complete: done)
    }
}
