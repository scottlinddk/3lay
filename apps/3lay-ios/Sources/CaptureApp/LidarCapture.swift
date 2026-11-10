#if os(iOS)
import ARKit
import CaptureKit
import CoreImage
import Foundation
import ImageIO
import RealityKit
import SwiftUI
import simd

/// The second capture mode: ARKit's LiDAR scene mesh plus posed photos, for rooms and large objects.
/// (Object Capture, in `CaptureScreen`, stays the mode for small objects.)
///
/// While you walk, the LiDAR mesh grows and a sharp photo is saved whenever you have moved enough
/// since the last one. `finish` writes a bundle folder (see `LidarManifest`) that 3lay Mac imports.
/// ARKit calls the delegate on the main queue, so the capture state below is main-thread only; JPEG
/// encoding and file writes run on `encodeQueue`.
final class LidarCapture: NSObject, ObservableObject, ARSessionDelegate {
    enum Failure: LocalizedError {
        case noFrame
        var errorDescription: String? { "The camera has not produced a frame yet. Move the phone a little and try again." }
    }

    static var isSupported: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) }

    static let maxPhotos = 400
    /// A photo needs this much movement or turning since the last one, and this long.
    private static let minimumDistance: Float = 0.06
    private static let minimumTurn: Float = 0.14  // radians, about 8 degrees
    private static let minimumInterval = 0.4
    /// Moving faster than this blurs the frame, so no photo is taken.
    private static let maximumSpeed: Float = 0.35  // meters per second
    private static let maximumTurnRate: Float = 0.8  // radians per second

    @Published private(set) var photoCount = 0
    @Published private(set) var triangleCount = 0
    @Published private(set) var warning: String?

    let folder: URL
    private weak var session: ARSession?
    private let encodeQueue = DispatchQueue(label: "app.scan3d.lidar.encode", qos: .userInitiated)
    private let ciContext = CIContext()
    // Main thread only:
    private var startTimestamp: TimeInterval?
    private var previous: (transform: simd_float4x4, time: TimeInterval)?
    private var lastPhoto: (transform: simd_float4x4, time: TimeInterval)?
    private var encoding = false
    private var queued = 0
    private var lastMeshCount = Date.distantPast
    // encodeQueue only:
    private var photos: [LidarManifest.Photo] = []

    init(folder: URL) {
        self.folder = folder
        super.init()
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
    }

    /// Starts tracking and LiDAR meshing on the preview's session.
    func attach(to session: ARSession) {
        self.session = session
        session.delegate = self
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification
        configuration.environmentTexturing = .none
        session.run(configuration)
    }

    func cancel() {
        session?.pause()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Frames

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        let transform = frame.camera.transform
        defer { previous = (transform, now) }
        if startTimestamp == nil { startTimestamp = now }

        updateTriangleCount(frame)

        guard case .normal = frame.camera.trackingState else {
            setWarning("Tracking is poor. Move slower and point at textured surfaces.")
            return
        }
        setWarning(nil)
        guard queued < Self.maxPhotos, !encoding else { return }

        if let previous, now > previous.time {
            let dt = Float(now - previous.time)
            let speed = simd_distance(Self.position(transform), Self.position(previous.transform)) / dt
            let turn = Self.angle(Self.forward(transform), Self.forward(previous.transform)) / dt
            if speed > Self.maximumSpeed || turn > Self.maximumTurnRate { return }  // too blurry
        }
        if let last = lastPhoto {
            guard now - last.time >= Self.minimumInterval else { return }
            let moved = simd_distance(Self.position(transform), Self.position(last.transform))
            let turned = Self.angle(Self.forward(transform), Self.forward(last.transform))
            guard moved >= Self.minimumDistance || turned >= Self.minimumTurn else { return }
        }

        lastPhoto = (transform, now)
        encoding = true
        queued += 1
        let index = queued
        let buffer = frame.capturedImage
        let intrinsics = frame.camera.intrinsics
        let seconds = now - (startTimestamp ?? now)
        let flat = Self.flatten(transform)
        encodeQueue.async { [weak self] in
            guard let self else { return }
            let name = String(format: "photos/%04d.jpg", index)
            if let jpeg = try? self.ciContext.jpegRepresentation(
                of: CIImage(cvPixelBuffer: buffer), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]),
               (try? jpeg.write(to: self.folder.appendingPathComponent(name), options: .atomic)) != nil {
                self.photos.append(LidarManifest.Photo(
                    file: name, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                    timestamp: seconds, transform: flat,
                    intrinsics: [intrinsics[0][0], intrinsics[1][1], intrinsics[2][0], intrinsics[2][1]]))
            }
            let count = self.photos.count
            DispatchQueue.main.async {
                self.photoCount = count
                self.encoding = false
            }
        }
    }

    private func updateTriangleCount(_ frame: ARFrame) {
        guard Date().timeIntervalSince(lastMeshCount) >= 1 else { return }
        lastMeshCount = Date()
        let count = frame.anchors.compactMap { $0 as? ARMeshAnchor }.reduce(0) { $0 + $1.geometry.faces.count }
        if count != triangleCount { triangleCount = count }
    }

    private func setWarning(_ text: String?) { if warning != text { warning = text } }

    // MARK: Finishing

    struct Result {
        let folder: URL
        let photos: Int
        let triangles: Int
    }

    /// Stops the session and writes `mesh/scan.ply` and `manifest.json` into `folder`.
    func finish(device: CaptureManifest.Device) throws -> Result {
        guard let frame = session?.currentFrame else { throw Failure.noFrame }
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        session?.pause()
        let (vertices, triangles) = Self.extractMesh(anchors)
        let photos = encodeQueue.sync { self.photos }  // waits for photos still being written
        let meshDirectory = folder.appendingPathComponent("mesh")
        try FileManager.default.createDirectory(at: meshDirectory, withIntermediateDirectories: true)
        try PLYWriter.write(vertices: vertices, triangles: triangles, to: meshDirectory.appendingPathComponent("scan.ply"))
        let manifest = LidarManifest(
            createdAt: Date(), device: device, vertexCount: vertices.count, triangleCount: triangles.count, photos: photos)
        try CaptureManifest.encoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        return Result(folder: folder, photos: photos.count, triangles: triangles.count)
    }

    /// All mesh anchors in one mesh, in meters. ARKit's world is Y up; the file is Z up (what the plate
    /// and slicers expect): (x, y, z) becomes (x, -z, y), a plain rotation, so triangle winding is kept.
    static func extractMesh(_ anchors: [ARMeshAnchor]) -> ([SIMD3<Float>], [SIMD3<UInt32>]) {
        var vertices: [SIMD3<Float>] = []
        var triangles: [SIMD3<UInt32>] = []
        for anchor in anchors {
            let geometry = anchor.geometry
            let base = UInt32(vertices.count)
            let source = geometry.vertices
            let points = source.buffer.contents().advanced(by: source.offset)
            for i in 0..<source.count {
                let p = points.advanced(by: i * source.stride)
                let local = SIMD4<Float>(
                    p.loadUnaligned(as: Float.self), p.loadUnaligned(fromByteOffset: 4, as: Float.self),
                    p.loadUnaligned(fromByteOffset: 8, as: Float.self), 1)
                let world = anchor.transform * local
                vertices.append(SIMD3(world.x, -world.z, world.y))
            }
            let faces = geometry.faces
            let indices = faces.buffer.contents()
            func index(_ n: Int) -> UInt32 {
                let at = indices.advanced(by: n * faces.bytesPerIndex)
                return faces.bytesPerIndex == 2 ? UInt32(at.loadUnaligned(as: UInt16.self)) : at.loadUnaligned(as: UInt32.self)
            }
            for f in 0..<faces.count {
                triangles.append(SIMD3(base + index(f * 3), base + index(f * 3 + 1), base + index(f * 3 + 2)))
            }
        }
        return (vertices, triangles)
    }

    // MARK: Math

    private static func position(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }
    private static func forward(_ m: simd_float4x4) -> SIMD3<Float> { -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) }
    private static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { acos(max(-1, min(1, simd_dot(a, b)))) }
    private static func flatten(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}

/// The camera view with ARKit's mesh overlay, so the user sees what LiDAR has covered.
struct LidarPreview: UIViewRepresentable {
    let capture: LidarCapture

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        view.debugOptions = [.showSceneUnderstanding]
        capture.attach(to: view.session)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) { uiView.session.pause() }
}
#endif
