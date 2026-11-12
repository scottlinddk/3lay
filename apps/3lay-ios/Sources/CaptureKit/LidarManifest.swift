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
/// `3lay-lidar/3` adds depth keyframes (`depthFrames`, with their own poses), an optional RoomPlan sidecar (`room`)
/// and a `highRes` flag on photos. `3lay-lidar/2` only adds fields. A reader that knows version 1 still reads every field it knew, and
/// the Mac importer accepts any `3lay-lidar/` format, so older Macs keep importing new bundles
/// (they ignore the depth data).
public struct LidarManifest: Codable, Equatable {
    public static let formatV1 = "3lay-lidar/1"
    public static let formatV2 = "3lay-lidar/2"
    public static let formatV3 = "3lay-lidar/3"
    /// What new bundles are written as.
    public static let format = formatV2
    /// Capability tags a bundle can carry, so a reader can check what it understands.
    public static let depthCapability = "depth/1"
    /// v3: `depthFrames` holds depth observations that are not tied to a photo.
    public static let depthFramesCapability = "depth-frames/1"
    /// v3: `room` points at a RoomPlan layout (`room/room.json`).
    public static let roomCapability = "room/1"
    /// v3: at least one photo is a full-resolution still (`highRes`).
    public static let highResCapability = "highres/1"

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

    /// v3: a depth observation with its own pose, taken at its own rate (several per second), so the Mac
    /// has far more depth than photos. Float16 halves the size; LiDAR noise is far above Float16 rounding.
    public struct DepthFrame: Codable, Equatable {
        public enum Encoding: String, Codable {
            /// IEEE half precision, little-endian, meters along the optical axis.
            case float16
            /// IEEE single precision, little-endian, meters along the optical axis.
            case float32
            public var bytesPerPixel: Int { self == .float16 ? 2 : 4 }
        }
        public var file: String
        /// UInt8 per pixel: 0 low, 1 medium, 2 high confidence. Same pixel grid as the depth map.
        public var confidenceFile: String
        public var width: Int
        public var height: Int
        public var encoding: Encoding
        /// Seconds since the scan started.
        public var timestamp: Double
        /// Camera to world, 16 floats column-major, same convention as `Photo.transform`.
        public var transform: [Float]
        /// fx, fy, cx, cy in pixels of this depth map.
        public var intrinsics: [Float]
        public var smoothed: Bool

        public init(
            file: String, confidenceFile: String, width: Int, height: Int, encoding: Encoding, timestamp: Double,
            transform: [Float], intrinsics: [Float], smoothed: Bool = false
        ) {
            self.file = file; self.confidenceFile = confidenceFile; self.width = width; self.height = height
            self.encoding = encoding; self.timestamp = timestamp; self.transform = transform
            self.intrinsics = intrinsics; self.smoothed = smoothed
        }
    }

    /// v3: Apple RoomPlan's layout of the scanned room (walls, doors, windows, furniture boxes). Only for rooms
    /// and large objects; RoomPlan does not model small objects. `file` is RoomPlan's `CapturedRoom` as JSON in
    /// the same ARKit world as the photos (meters, +Y up).
    public struct Room: Codable, Equatable {
        public var file: String
        /// RoomPlan's raw `CapturedRoomData`, so the layout can be rebuilt later.
        public var data: String?
        public var usdz: String?
        public var walls: Int
        public var doors: Int
        public var windows: Int
        public var openings: Int
        public var objects: Int

        public init(file: String, data: String? = nil, usdz: String? = nil,
                    walls: Int = 0, doors: Int = 0, windows: Int = 0, openings: Int = 0, objects: Int = 0) {
            self.file = file; self.data = data; self.usdz = usdz
            self.walls = walls; self.doors = doors; self.windows = windows; self.openings = openings; self.objects = objects
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
        /// v3: a full-resolution still (`captureHighResolutionFrame`) instead of a video frame. Its `depth`, if
        /// any, comes from the video frame a moment earlier: see `Depth.timeOffset`.
        public var highRes: Bool?

        public init(
            file: String, width: Int, height: Int, timestamp: Double, transform: [Float], intrinsics: [Float],
            trackingState: String? = nil, exposure: Exposure? = nil, depth: Depth? = nil, highRes: Bool? = nil
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
            self.highRes = highRes
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
    /// v3: depth keyframes with their own poses. nil or empty when there are none.
    public var depthFrames: [DepthFrame]?
    /// v3: RoomPlan layout, for rooms and large objects.
    public var room: Room?

    /// The format and capability list follow what the bundle actually contains, so a reader can trust them.
    public init(
        createdAt: Date, device: CaptureManifest.Device, vertexCount: Int, triangleCount: Int, photos: [Photo],
        depthFrames: [DepthFrame] = [], room: Room? = nil
    ) {
        let hasDepth = photos.contains { $0.depth != nil }
        let hasFrames = !depthFrames.isEmpty
        let hasHighRes = photos.contains { $0.highRes == true }
        var tags: [String] = []
        if hasDepth { tags.append(LidarManifest.depthCapability) }
        if hasFrames { tags.append(LidarManifest.depthFramesCapability) }
        if room != nil { tags.append(LidarManifest.roomCapability) }
        if hasHighRes { tags.append(LidarManifest.highResCapability) }
        if hasFrames || room != nil || hasHighRes {
            format = LidarManifest.formatV3
        } else {
            format = hasDepth ? LidarManifest.formatV2 : LidarManifest.formatV1
        }
        capabilities = tags.isEmpty ? nil : tags
        meshFromWorld = tags.isEmpty ? nil : LidarGeometry.meshFromWorld.flatMatrix
        self.depthFrames = hasFrames ? depthFrames : nil
        self.room = room
        self.createdAt = createdAt
        self.device = device
        units = "meters"
        meshFile = "mesh/scan.ply"
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
        self.photos = photos
    }
}
