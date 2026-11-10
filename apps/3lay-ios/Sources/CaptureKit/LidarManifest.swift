import Foundation

/// `3lay-lidar/1`: the manifest inside a LiDAR scan bundle (`manifest.json`).
///
/// ```
/// <bundle>/manifest.json
/// <bundle>/mesh/scan.ply     binary PLY, meters, Z up, origin where the scan started
/// <bundle>/photos/NNNN.jpg   raw sensor orientation; `intrinsics` match these pixels
/// ```
public struct LidarManifest: Codable, Equatable {
    public static let format = "3lay-lidar/1"

    public struct Photo: Codable, Equatable {
        public var file: String
        public var width: Int
        public var height: Int
        /// Seconds since the scan started.
        public var timestamp: Double
        /// Camera to world, 16 floats, column-major, in ARKit world coordinates (meters, Y up,
        /// camera looks down its -Z). Not the same axes as the mesh, which is rotated to Z up.
        public var transform: [Float]
        /// fx, fy, cx, cy in pixels of the JPEG.
        public var intrinsics: [Float]

        public init(file: String, width: Int, height: Int, timestamp: Double, transform: [Float], intrinsics: [Float]) {
            self.file = file
            self.width = width
            self.height = height
            self.timestamp = timestamp
            self.transform = transform
            self.intrinsics = intrinsics
        }
    }

    public var format: String
    public var createdAt: Date
    public var device: CaptureManifest.Device
    public var units: String
    public var meshFile: String
    public var vertexCount: Int
    public var triangleCount: Int
    public var photos: [Photo]

    public init(createdAt: Date, device: CaptureManifest.Device, vertexCount: Int, triangleCount: Int, photos: [Photo]) {
        format = LidarManifest.format
        self.createdAt = createdAt
        self.device = device
        units = "meters"
        meshFile = "mesh/scan.ply"
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.photos = photos
    }
}
