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
        case invalidBundle(String)
        var errorDescription: String? {
            switch self {
            case .noFrame: return "The camera has not produced a frame yet. Move the phone a little and try again."
            case .notCapturing: return "This scan is already being saved or was cancelled."
            case .invalidBundle(let why): return "The scan is incomplete (\(why))."
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
    private var policy = CapturePolicy()
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
        // Depth and confidence for every photo, so the Mac can fuse them instead of only using the final mesh.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
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
        if startTimestamp == nil { startTimestamp = now }

        updateTriangleCount(frame)
        sampleDiagnostics(frame)

        var tracking = false
        if case .normal = frame.camera.trackingState { tracking = true }
        let candidate = CapturePolicy.Frame(
            transform: transform, time: now, trackingNormal: tracking, sharpness: nil,
            exposureDuration: frame.camera.exposureDuration)
        let buffer = frame.capturedImage
        switch policy.evaluate(
            candidate, thermal: Self.thermal, busy: encoding,
            measureSharpness: { Self.sharpness(of: buffer) }
        ) {
        case .skip(let reason):
            // Only reasons the person can act on are shown; the rest (too soon, same view) are silent.
            setWarning(reason.guidance)
            return
        case .take:
            setWarning(Self.thermal >= .serious ? "The phone is warm, so photos are taken less often." : nil)
        }

        encoding = true
        queued += 1
        let index = queued
        let intrinsics = frame.camera.intrinsics
        let seconds = now - (startTimestamp ?? now)
        let flat = Self.flatten(transform)
        // Copied now: ARKit reuses these buffers. Depth belongs to this same frame as the photo.
        let depth = Self.copyDepth(frame)
        let exposure = LidarManifest.Exposure(
            duration: frame.camera.exposureDuration, offset: frame.camera.exposureOffset,
            ambientIntensity: frame.lightEstimate.map { Float($0.ambientIntensity) })
        encodeQueue.async { [weak self] in
            guard let self else { return }
            let name = String(format: "photos/%04d.jpg", index)
            if self.acceptingWrites, let jpeg = try? self.ciContext.jpegRepresentation(
                of: CIImage(cvPixelBuffer: buffer), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]),
               (try? jpeg.write(to: self.folder.appendingPathComponent(name), options: .atomic)) != nil {
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                let k = [intrinsics[0][0], intrinsics[1][1], intrinsics[2][0], intrinsics[2][1]]
                self.photos.append(LidarManifest.Photo(
                    file: name, width: width, height: height, timestamp: seconds, transform: flat, intrinsics: k,
                    trackingState: "normal", exposure: exposure,
                    depth: depth.flatMap { self.writeDepth($0, index: index, photoSize: (width, height), photoIntrinsics: k) }))
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

    // MARK: Quality

    private static var thermal: CapturePolicy.Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    /// Relative sharpness of the camera's luma plane (see `CapturePolicy.sharpness`).
    private static func sharpness(of buffer: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPlaneCount(buffer) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        return CapturePolicy.sharpness(width: width, height: height) { x, y in luma[y * stride + x] }
    }

    // MARK: Depth

    struct DepthCopy {
        let depth: Data, confidence: Data
        let width: Int, height: Int
        let smoothed: Bool
    }

    /// Packed copies (no row padding) of this frame's depth (Float32 meters) and confidence (UInt8).
    private static func copyDepth(_ frame: ARFrame) -> DepthCopy? {
        guard let data = frame.sceneDepth, let confidence = data.confidenceMap,
              let depth = packed(data.depthMap, bytesPerPixel: MemoryLayout<Float32>.size),
              let conf = packed(confidence, bytesPerPixel: 1),
              depth.width == conf.width, depth.height == conf.height else { return nil }
        return DepthCopy(depth: depth.data, confidence: conf.data, width: depth.width, height: depth.height, smoothed: false)
    }

    private static func packed(_ buffer: CVPixelBuffer, bytesPerPixel: Int) -> (data: Data, width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer), row = width * bytesPerPixel
        guard width > 0, height > 0, stride >= row else { return nil }
        var data = Data(capacity: row * height)
        for y in 0..<height { data.append(Data(bytes: base.advanced(by: y * stride), count: row)) }
        return (data, width, height)
    }

    /// Writes `depth/NNNN.depth` and `.conf` (encodeQueue). nil if either write fails: the photo is still
    /// kept, just without depth.
    private func writeDepth(
        _ copy: DepthCopy, index: Int, photoSize: (width: Int, height: Int), photoIntrinsics: [Float]
    ) -> LidarManifest.Depth? {
        guard acceptingWrites, let k = LidarGeometry.Intrinsics(photoIntrinsics) else { return nil }
        let directory = folder.appendingPathComponent("depth")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let depthName = String(format: "depth/%04d.depth", index), confName = String(format: "depth/%04d.conf", index)
        do {
            try copy.depth.write(to: folder.appendingPathComponent(depthName), options: .atomic)
            try copy.confidence.write(to: folder.appendingPathComponent(confName), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(depthName))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(confName))
            return nil
        }
        let scaled = k.scaled(from: photoSize, to: (copy.width, copy.height))
        return LidarManifest.Depth(
            file: depthName, confidenceFile: confName, width: copy.width, height: copy.height,
            intrinsics: scaled.array, timeOffset: 0, smoothed: copy.smoothed)
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
            let manifest = try Self.validated(LidarManifest(
                createdAt: Date(), device: device, vertexCount: summary.vertexCount,
                triangleCount: summary.triangleCount, photos: photos), in: folder)
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

    /// A bundle must pass `LidarBundleValidator` before it is declared complete. Depth that fails (missing or
    /// misaligned) is dropped from that photo, because the photo itself is still good; anything else that
    /// fails stops the save with the reason, rather than shipping a bundle the Mac cannot trust.
    static func validated(_ manifest: LidarManifest, in folder: URL) throws -> LidarManifest {
        var manifest = manifest
        let issues = LidarBundleValidator.validate(manifest: manifest, in: folder)
        guard !issues.isEmpty else { return manifest }
        let badDepth = Set(issues.compactMap(\.photo))
        for i in manifest.photos.indices where badDepth.contains(manifest.photos[i].file) && manifest.photos[i].depth != nil {
            if let depth = manifest.photos[i].depth {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(depth.file))
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(depth.confidenceFile))
            }
            manifest.photos[i].depth = nil
        }
        // Rebuild so format and capabilities follow what is actually in the bundle.
        let rebuilt = LidarManifest(
            createdAt: manifest.createdAt, device: manifest.device, vertexCount: manifest.vertexCount,
            triangleCount: manifest.triangleCount, photos: manifest.photos)
        let remaining = LidarBundleValidator.validate(manifest: rebuilt, in: folder)
        if let first = remaining.first { throw Failure.invalidBundle(first.description) }
        return rebuilt
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
