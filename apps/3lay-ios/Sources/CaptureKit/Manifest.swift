import Foundation

/// `capture-bundle/1`: describes a raw photo capture. See docs/ARCHITECTURE.md section 5.1.
public struct CaptureManifest: Codable, Equatable {
    public static let schema = "capture-bundle/1"

    public struct Device: Codable, Equatable {
        public var model: String
        public var systemVersion: String
        public var appVersion: String
        public var hasLiDAR: Bool

        public init(model: String, systemVersion: String, appVersion: String, hasLiDAR: Bool) {
            self.model = model
            self.systemVersion = systemVersion
            self.appVersion = appVersion
            self.hasLiDAR = hasLiDAR
        }
    }

    public struct File: Codable, Equatable {
        public var path: String
        public var sha256: String
        public var bytes: Int
    }

    /// Scale evidence. Sensor units are provenance, not a guarantee of accuracy.
    public struct Scale: Codable, Equatable {
        public var declaredUnits: String   // "meters" or "unknown"
        public var provenance: String      // "sensor-lidar" or "none"
    }

    public var schema: String
    public var createdAt: Date
    public var device: Device
    public var scale: Scale
    public var images: [File]

    public init(createdAt: Date, device: Device, scale: Scale, images: [File]) {
        self.schema = CaptureManifest.schema
        self.createdAt = createdAt
        self.device = device
        self.scale = scale
        self.images = images
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
