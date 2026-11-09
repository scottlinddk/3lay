import Foundation

/// Constants shared by the Mac receiver (Scanbench) and the iOS sender. Change them here only,
/// and update docs/LAN_LINK.md in the same commit.
public enum LanProtocol {
    /// Bonjour service type the Mac advertises and the phone browses for.
    public static let serviceType = "_scanbench._tcp"
    /// Port Scanbench tries first. Clients must use the port from Bonjour, not assume this one.
    public static let defaultPort: UInt16 = 8765
    public static let version = 1
    public static let serviceName = "scanbench"

    public static let helloPath = "/api/hello"
    public static let authPath = "/api/auth"
    public static let uploadPrefix = "/upload/"

    public static let maxUploadBytes = 100_000_000
    public static let acceptedExtensions = ["stl", "obj", "ply", "usdz"]
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

    public init(name: String) {
        service = LanProtocol.serviceName
        version = LanProtocol.version
        self.name = name
        maxBytes = LanProtocol.maxUploadBytes
        extensions = LanProtocol.acceptedExtensions
    }
}
