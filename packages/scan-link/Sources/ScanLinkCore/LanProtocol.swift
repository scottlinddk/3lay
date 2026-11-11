import Foundation

/// Constants shared by the Mac receiver (ThreeLayMacOS) and the iOS sender. Change them here only,
/// and update docs/LAN_LINK.md in the same commit.
public enum LanProtocol {
    /// Bonjour service type the Mac advertises and the phone browses for.
    public static let serviceType = "_threelaymacos._tcp"
    /// Port ThreeLayMacOS tries first. Clients must use the port from Bonjour, not assume this one.
    public static let defaultPort: UInt16 = 8765
    public static let version = 1
    public static let serviceName = "threelaymacos"

    public static let helloPath = "/api/hello"
    public static let authPath = "/api/auth"
    public static let uploadPrefix = "/upload/"
    /// Resumable uploads (see `LanTransferStore`).
    public static let transfersPrefix = "/transfers/"
    /// Bytes per PATCH. Small enough to retry cheaply, large enough to keep Wi-Fi busy.
    public static let transferChunkBytes = 4 * 1024 * 1024

    public static let maxUploadBytes = 100_000_000
    public static let acceptedExtensions = ["stl", "obj", "ply", "usdz"]
    /// A zip of the capture photos. The Mac builds the model itself, which is much faster than the
    /// phone and gives more detail. Photos are far larger than a reduced mesh, hence the bigger limit.
    public static let captureArchiveExtension = "zip"
    public static let maxCaptureBytes = 2_000_000_000
    /// A LiDAR scan bundle: ARKit mesh plus posed photos (see docs/LAN_LINK.md). It is a zip too, so
    /// it passes `isCaptureArchive`; the Mac tells the two apart by this suffix.
    public static let lidarBundleSuffix = ".lidar.zip"
    public static let codeLength = 6

    /// Failed code attempts allowed before the receiver locks for `lockoutSeconds`.
    public static let maxFailedAttempts = 5
    public static let lockoutSeconds: TimeInterval = 60

    public static func isValidCode(_ code: String) -> Bool {
        code.count == codeLength && code.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public static func isAcceptedFilename(_ name: String) -> Bool {
        acceptedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    public static func isCaptureArchive(_ name: String) -> Bool {
        (name as NSString).pathExtension.lowercased() == captureArchiveExtension
    }

    /// A LiDAR scan bundle (`*.lidar.zip`). Not a pile of photos for Object Capture.
    public static func isLidarBundle(_ name: String) -> Bool {
        name.lowercased().hasSuffix(lidarBundleSuffix)
    }

    /// A mesh file or a capture archive: everything the receiver takes.
    public static func isAcceptedUpload(_ name: String) -> Bool {
        isAcceptedFilename(name) || isCaptureArchive(name)
    }

    /// Size limit for this file name.
    public static func maxBytes(for name: String) -> Int {
        isCaptureArchive(name) ? maxCaptureBytes : maxUploadBytes
    }

    /// The path a client PUTs a file to. The name is percent-encoded as a single path segment.
    public static func uploadPath(for filename: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let leaf = (filename as NSString).lastPathComponent
        return uploadPrefix + (leaf.addingPercentEncoding(withAllowedCharacters: allowed) ?? leaf)
    }
}

/// Body of `GET /api/hello`. Public information, no code needed. It never contains the code.
public struct LanHello: Codable, Equatable {
    public var service: String
    public var version: Int
    public var name: String
    public var maxBytes: Int
    public var extensions: [String]
    /// Largest capture archive the Mac takes. nil on a Mac that only accepts finished meshes, so
    /// the phone knows to build the model itself.
    public var maxCaptureBytes: Int?
    /// true when the Mac imports `*.lidar.zip` bundles. nil on an older Mac, which would treat the
    /// zip as a pile of photos and fail confusingly, so the phone checks this first.
    public var supportsLidarBundles: Bool?
    /// true when the Mac supports resumable `/transfers/` uploads. nil on an older Mac: use `PUT`.
    public var supportsResumableUploads: Bool?

    public init(name: String) {
        service = LanProtocol.serviceName
        version = LanProtocol.version
        self.name = name
        maxBytes = LanProtocol.maxUploadBytes
        extensions = LanProtocol.acceptedExtensions
        maxCaptureBytes = LanProtocol.maxCaptureBytes
        supportsLidarBundles = true
        supportsResumableUploads = true
    }
}

extension LanProtocol {
    public static func transferPath(id: String) -> String { transfersPrefix + id }
}
