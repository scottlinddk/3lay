import Foundation

/// The manifest inside a LiDAR scan bundle (`manifest.json`). Full conventions: docs/LIDAR_BUNDLE.md.
///
/// ```
/// <bundle>/manifest.json
/// <bundle>/mesh/scan.ply     binary PLY, meters, Z up, origin where the scan started
/// <bundle>/photos/NNNN.jpg   raw sensor orientation; `intrinsics` match these pixels
/// <bundle>/depth/NNNN.depth  v2: Float32 little-endian meters, row-major, `depth.width` x `depth.height`
/// <bundle>/depth/NNNN.conf   v2: UInt8 per pixel, 0 low / 1 medium / 2 high confidence
/// ```
///
/// `3lay-lidar/2` only adds fields. A reader that knows version 1 still reads every field it knew, and
/// the Mac importer accepts any `3lay-lidar/` format, so older Macs keep importing new bundles
/// (they ignore the depth data).
public struct LidarManifest: Codable, Equatable {
    public static let formatV1 = "3lay-lidar/1"
    public static let formatV2 = "3lay-lidar/2"
    /// What new bundles are written as.
    public static let format = formatV2
    /// Capability tags a bundle can carry, so a reader can check what it understands.
    public static let depthCapability = "depth/1"

    /// A depth observation for one photo. It comes from the same ARKit frame as the photo, so it covers
    /// the same field of view at lower resolution.
    public struct Depth: Codable, Equatable {
        public var file: String
        public var confidenceFile: String
        public var width: Int
        public var height: Int
        /// fx, fy, cx, cy in pixels of the depth map: the photo's intrinsics scaled by depth size / photo size.
        public var intrinsics: [Float]
        /// Seconds the depth observation lies after the photo's pixels were captured. 0 when both come from
        /// one ARKit frame (the case today). Non-zero means the camera moved in between: do not treat the
        /// depth as exact for that photo without using the pose recorded here.
        public var timeOffset: Double
        /// true if ARKit's temporally smoothed depth was used instead of the raw per-frame depth.
        public var smoothed: Bool

        public init(
            file: String, confidenceFile: String, width: Int, height: Int, intrinsics: [Float],
            timeOffset: Double = 0, smoothed: Bool = false
        ) {
            self.file = file; self.confidenceFile = confidenceFile; self.width = width; self.height = height
            self.intrinsics = intrinsics; self.timeOffset = timeOffset; self.smoothed = smoothed
        }
    }

    public struct Exposure: Codable, Equatable {
        public var duration: Double
        public var offset: Float
        public var ambientIntensity: Float?
        public init(duration: Double, offset: Float, ambientIntensity: Float?) {
            self.duration = duration; self.offset = offset; self.ambientIntensity = ambientIntensity
        }
    }

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
        /// v2: "normal", or why ARKit was unsure ("limited: excessiveMotion", ...).
        public var trackingState: String?
        public var exposure: Exposure?
        public var depth: Depth?

        public init(
            file: String, width: Int, height: Int, timestamp: Double, transform: [Float], intrinsics: [Float],
            trackingState: String? = nil, exposure: Exposure? = nil, depth: Depth? = nil
        ) {
            self.file = file
            self.width = width
            self.height = height
            self.timestamp = timestamp
            self.transform = transform
            self.intrinsics = intrinsics
            self.trackingState = trackingState
            self.exposure = exposure
            self.depth = depth
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
    /// v2: what the bundle contains beyond version 1, e.g. `depth/1`.
    public var capabilities: [String]?
    /// v2: rotation from ARKit world coordinates (Y up, as used by photo transforms) to mesh coordinates
    /// (Z up), 16 floats column-major. Written out so a reader never has to guess the axes.
    public var meshFromWorld: [Float]?

    public init(createdAt: Date, device: CaptureManifest.Device, vertexCount: Int, triangleCount: Int, photos: [Photo]) {
        let hasDepth = photos.contains { $0.depth != nil }
        format = hasDepth ? LidarManifest.formatV2 : LidarManifest.formatV1
        capabilities = hasDepth ? [LidarManifest.depthCapability] : nil
        meshFromWorld = hasDepth ? LidarGeometry.meshFromWorld.flatMatrix : nil
        self.createdAt = createdAt
        self.device = device
        units = "meters"
        meshFile = "mesh/scan.ply"
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.photos = photos
    }
}
