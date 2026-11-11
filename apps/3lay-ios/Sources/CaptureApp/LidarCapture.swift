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
        case notCapturing
        var errorDescription: String? {
            switch self {
            case .noFrame: return "The camera has not produced a frame yet. Move the phone a little and try again."
            case .notCapturing: return "This scan is already being saved or was cancelled."
            }
        }
    }

    /// Where the scan is in its life. Only `capturing` takes frames or starts a save, so Finish cannot
    /// run twice and a cancelled scan cannot be saved.
    enum State: Equatable {
        case capturing
        case finishing
        case saved
        case cancelling
        case failed(String)
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
    @Published private(set) var state: State = .capturing

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
    private var finishTask: Task<Result, Error>?
    // encodeQueue only:
    private var photos: [LidarManifest.Photo] = []
    private var acceptingWrites = true

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

    /// Stops the session, waits for any write that is still running, and only then deletes the folder,
    /// so a late photo or the mesh save cannot recreate files after they were removed.
    @MainActor
    func cancel() async {
        guard state != .cancelling else { return }
        state = .cancelling
        session?.pause()
        finishTask?.cancel()
        _ = try? await finishTask?.value  // a running save finishes first; its output is then deleted
        await stopEncoding()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Refuses further photo writes and returns once every queued one has completed or been skipped.
    private func stopEncoding() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            encodeQueue.async {
                self.acceptingWrites = false
                done.resume()
            }
        }
    }

    // MARK: Frames

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard state == .capturing else { return }
        let now = frame.timestamp
        let transform = frame.camera.transform
        defer { previous = (transform, now) }
        if startTimestamp == nil { startTimestamp = now }

        updateTriangleCount(frame)
        sampleDiagnostics(frame)

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
            if self.acceptingWrites, let jpeg = try? self.ciContext.jpegRepresentation(
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

    private var lastSample = Date.distantPast
    /// About once a second: thermal state, memory, pending photo writes and how old this frame is.
    private func sampleDiagnostics(_ frame: ARFrame) {
        guard Date().timeIntervalSince(lastSample) >= 1 else { return }
        lastSample = Date()
        Diagnostics.record(Diagnostics.sample(
            pendingWork: encoding ? 1 : 0, frameAge: ProcessInfo.processInfo.systemUptime - frame.timestamp))
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

    /// Stops the session and writes `mesh/scan.ply` and `manifest.json` into `folder`, off the main
    /// thread. The manifest is written last: a folder with a manifest is a complete scan.
    @MainActor
    func finish(device: CaptureManifest.Device) async throws -> Result {
        guard state == .capturing else { throw Failure.notCapturing }
        guard let frame = session?.currentFrame else { throw Failure.noFrame }
        state = .finishing
        // ARKit may keep changing its mesh buffers, so copy them now; everything after works on the copies.
        let chunks = Self.snapshot(frame.anchors.compactMap { $0 as? ARMeshAnchor })
        session?.pause()
        let folder = self.folder
        let task = Task.detached(priority: .userInitiated) { [self] () -> Result in
            let photos = await self.drainPhotos()  // waits for photos still being written
            try Task.checkCancellation()
            let meshDirectory = folder.appendingPathComponent("mesh")
            try FileManager.default.createDirectory(at: meshDirectory, withIntermediateDirectories: true)
            let summary = try Diagnostics.measure("lidar.writeMesh") {
                try PLYWriter.write(chunks: chunks, to: meshDirectory.appendingPathComponent("scan.ply"))
            }
            try Task.checkCancellation()
            let manifest = LidarManifest(
                createdAt: Date(), device: device, vertexCount: summary.vertexCount,
                triangleCount: summary.triangleCount, photos: photos)
            try CaptureManifest.encoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            return Result(folder: folder, photos: photos.count, triangles: summary.triangleCount)
        }
        finishTask = task
        do {
            let result = try await task.value
            if state == .finishing { state = .saved }
            return result
        } catch {
            // Keep the photos, drop the half-made mesh so nothing looks like a finished scan.
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("mesh"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("manifest.json"))
            if state == .finishing { state = .failed(error.localizedDescription) }
            throw error
        }
    }

    private func drainPhotos() async -> [LidarManifest.Photo] {
        await withCheckedContinuation { (done: CheckedContinuation<[LidarManifest.Photo], Never>) in
            encodeQueue.async { done.resume(returning: self.photos) }
        }
    }

    /// Copies each anchor's vertices (tightly packed) and faces out of ARKit's buffers.
    static func snapshot(_ anchors: [ARMeshAnchor]) -> [MeshChunk] {
        anchors.compactMap { anchor in
            let geometry = anchor.geometry
            let vertices = geometry.vertices, faces = geometry.faces
            guard vertices.count > 0, faces.count > 0 else { return nil }
            var vertexData = Data(capacity: vertices.count * 12)
            let base = vertices.buffer.contents().advanced(by: vertices.offset)
            if vertices.stride == 12 {
                vertexData.append(Data(bytes: base, count: vertices.count * 12))
            } else {
                for i in 0..<vertices.count { vertexData.append(Data(bytes: base.advanced(by: i * vertices.stride), count: 12)) }
            }
            let faceData = Data(bytes: faces.buffer.contents(), count: faces.count * 3 * faces.bytesPerIndex)
            return MeshChunk(
                transform: anchor.transform, vertexData: vertexData, vertexCount: vertices.count,
                faceData: faceData, faceCount: faces.count, bytesPerIndex: faces.bytesPerIndex)
        }
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
