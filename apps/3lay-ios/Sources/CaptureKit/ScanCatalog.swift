import Foundation

/// One scan the app is responsible for, from first frame until it reached its destination.
public struct ScanRecord: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case object, lidar }

    public enum Status: String, Codable {
        /// Being captured. After a relaunch this means the app died mid-capture.
        case capturing
        /// Capture ended; files are being written. After a relaunch the app died mid-write.
        case saving
        /// Complete on disk and not yet delivered.
        case saved
        /// A transfer was running. After a relaunch it was interrupted and can be retried.
        case sending
        /// Delivered. Sources may still be on disk until `pruneDelivered` removes them.
        case sent
        /// A failed step; `lastError` says which. Sources are kept.
        case failed
        /// Some files exist, but the scan cannot be used as it is (for example no manifest).
        case incomplete
    }

    public let id: UUID
    public var kind: Kind
    public var name: String
    public var createdAt: Date
    public var status: Status
    /// Relative to the catalog root, so records survive the app container moving (it can on reinstall/restore).
    public var folder: String
    public var photoCount: Int
    public var triangleCount: Int
    /// Mac or server the scan was last sent (or is being sent) to.
    public var destination: String?
    /// Server job created for this scan. Kept so a retry continues that job instead of opening a second one.
    public var serverJobId: String?
    public var lastError: String?

    public init(
        id: UUID = UUID(), kind: Kind, name: String = "", createdAt: Date = Date(), status: Status,
        folder: String, photoCount: Int = 0, triangleCount: Int = 0, destination: String? = nil,
        serverJobId: String? = nil, lastError: String? = nil
    ) {
        self.id = id; self.kind = kind; self.name = name; self.createdAt = createdAt; self.status = status
        self.folder = folder; self.photoCount = photoCount; self.triangleCount = triangleCount
        self.destination = destination; self.serverJobId = serverJobId; self.lastError = lastError
    }

    /// Whether the user can still send it.
    public var isRecoverable: Bool { status == .saved || status == .failed || status == .sending }
    public var isDelivered: Bool { status == .sent }
}

/// Atomic, file-backed list of scans. All mutations rewrite the whole file with `.atomic`, so a crash
/// leaves either the old or the new list, never a torn one. Call from one actor (the app model).
public final class ScanCatalog {
    private let url: URL
    /// Scan folders are stored relative to this directory.
    public let root: URL
    private var records: [ScanRecord]

    public init(url: URL, root: URL) {
        self.url = url
        self.root = root
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([ScanRecord].self, from: Data(contentsOf: url))) ?? []
    }

    public static func standard() -> ScanCatalog {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ScanCatalog(url: support.appendingPathComponent("scan-catalog.json"), root: documents)
    }

    public var all: [ScanRecord] { records.sorted { $0.createdAt > $1.createdAt } }
    public func record(id: UUID) -> ScanRecord? { records.first { $0.id == id } }
    public func folderURL(_ record: ScanRecord) -> URL { root.appendingPathComponent(record.folder, isDirectory: true) }

    /// Relative path of `folder` under the root, or its full path if it lies elsewhere.
    public func relativePath(of folder: URL) -> String {
        let base = root.standardizedFileURL.path + "/"
        let path = folder.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    public func upsert(_ record: ScanRecord) throws {
        var updated = records
        if let i = updated.firstIndex(where: { $0.id == record.id }) { updated[i] = record } else { updated.append(record) }
        try persist(updated)
    }

    public func update(id: UUID, _ change: (inout ScanRecord) -> Void) throws {
        guard var record = record(id: id) else { return }
        change(&record)
        try upsert(record)
    }

    public func remove(id: UUID) throws { try persist(records.filter { $0.id != id }) }

    private func persist(_ updated: [ScanRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(updated).write(to: url, options: .atomic)
        records = updated
    }

    // MARK: Recovery

    public struct Reconciliation: Equatable {
        public var recovered: [UUID] = []
        public var incomplete: [UUID] = []
        public var dropped: [UUID] = []
    }

    /// Brings the list in line with the disk after a launch. Never deletes scan files: a record is only
    /// dropped when its folder is gone, and a scan that cannot be used is marked `incomplete` for the user
    /// to discard.
    @discardableResult
    public func reconcile() throws -> Reconciliation {
        var result = Reconciliation()
        var updated: [ScanRecord] = []
        for var record in records {
            let folder = folderURL(record)
            guard FileManager.default.fileExists(atPath: folder.path) else {
                result.dropped.append(record.id)
                continue
            }
            let complete = Self.hasCompleteFiles(record, at: folder)
            if complete {
                switch record.status {
                case .capturing, .saving, .incomplete:
                    record.status = .saved
                    result.recovered.append(record.id)
                case .sending:
                    record.status = .saved  // an interrupted transfer is simply retryable
                case .saved, .failed, .sent:
                    break
                }
            } else if record.status != .incomplete && record.status != .sent {
                record.status = .incomplete
                result.incomplete.append(record.id)
            }
            updated.append(record)
        }
        try persist(updated)
        return result
    }

    static func hasCompleteFiles(_ record: ScanRecord, at folder: URL) -> Bool {
        let fm = FileManager.default
        switch record.kind {
        case .lidar:
            return fm.fileExists(atPath: folder.appendingPathComponent("manifest.json").path)
                && fm.fileExists(atPath: folder.appendingPathComponent("mesh/scan.ply").path)
        case .object:
            return fm.fileExists(atPath: folder.appendingPathComponent("Images").path)
        }
    }

    // MARK: Storage

    /// Bytes the scan occupies on disk, for the storage summary.
    public func storageBytes(of record: ScanRecord) -> Int64 {
        Self.directorySize(folderURL(record))
    }

    public func totalStorageBytes() -> Int64 { records.reduce(0) { $0 + storageBytes(of: $1) } }

    static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Retention rule for delivered scans: their sources are deleted `retention` after creation
    /// (a week by default), so a scan can be re-sent for a while and disk use stays bounded.
    @discardableResult
    public func pruneDelivered(olderThan retention: TimeInterval = 7 * 24 * 3600, now: Date = Date()) throws -> [UUID] {
        let expired = records.filter { $0.status == .sent && now.timeIntervalSince($0.createdAt) > retention }
        for record in expired { try discard(id: record.id) }
        return expired.map(\.id)
    }

    /// Deletes the scan's files and its record. The one place scan data is removed, so every discard
    /// (explicit, or after a successful send) follows the same rule.
    public func discard(id: UUID) throws {
        guard let record = record(id: id) else { return }
        let folder = folderURL(record)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try remove(id: id)
    }
}
