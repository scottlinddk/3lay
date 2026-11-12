#if os(iOS)
import ARKit
import CaptureKit
import CoreImage
import Foundation
import ImageIO
import RealityKit
import SwiftUI
import UIKit
import simd

/// The second capture mode: ARKit's LiDAR scene mesh plus posed photos, for rooms and large objects.
/// (Object Capture, in `CaptureScreen`, stays the mode for small objects.)
///
/// While you walk, the LiDAR mesh grows, drawn red where photos are still missing and green where they are
/// enough. A sharp photo is saved when it adds surface that no earlier photo covers, depth keyframes are kept
/// several times a second, an occasional full-resolution still replaces a video frame, and RoomPlan records the
/// room layout on the same session. `finish` writes a bundle folder (see `LidarManifest`) that 3lay Mac imports.
///
/// Frames are polled from the session on the main thread (a display link), because RoomPlan owns the ARSession's
/// delegate. The capture state below is main-thread only; JPEG encoding and file writes run on `encodeQueue`,
/// mesh sampling on `coverageQueue`.
final class LidarCapture: NSObject, ObservableObject {
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
    /// Share (0 to 100) of the surface LiDAR has seen that photos already show well. Not the share of the room scanned.
    @Published private(set) var photoDetail = 0
    /// Coverage is decent and has stopped improving: more circling will not help.
    @Published private(set) var coveragePlateau = false
    @Published private(set) var depthFrameCount = 0
    @Published private(set) var highResCount = 0
    @Published private(set) var roomPlanActive = false

    let folder: URL
    private weak var session: ARSession?
    private let encodeQueue = DispatchQueue(label: "app.scan3d.lidar.encode", qos: .userInitiated)
    private let ciContext = CIContext()
    // Main thread only:
    private var startTimestamp: TimeInterval?
    private var policy = CapturePolicy()
    private var quality = ScanQualityAccumulator()

    var qualitySnapshot: ScanQualitySnapshot {
        quality.snapshot(photoCount: photoCount,
                         coverage: coverage.observedArea >= coverage.minimumAreaForPercent ? photoDetail : nil,
                         plateau: coveragePlateau, thermal: Diagnostics.sample().thermal)
    }
    private var encoding = false
    private var queued = 0
    private var lastMeshCount = Date.distantPast
    private var finishTask: Task<Result, Error>?
    private var roomFinishTask: Task<LidarManifest.Room?, Never>?
    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: TimeInterval = -1
    private var lastEnsure = Date.distantPast
    private var roomRecorder: RoomPlanRecorder?
    private var overlay: CoverageOverlay?  // holds the view weakly, so no cycle
    // Coverage (main thread only):
    private var coverage = CoverageMap()
    private var coverageVersion = 0
    private var plateau = CoveragePlateau()
    private var lastMeshSample = Date.distantPast
    private var lastPhotoTime: TimeInterval = -.infinity
    private var meshSampling = false
    private var meshSignatures: [UUID: SIMD2<Int>] = [:]
    // coverageQueue only:
    private let coverageQueue = DispatchQueue(label: "app.scan3d.lidar.coverage", qos: .utility)
    private let keyer = CoverageMap()
    private var seenCells = Set<SIMD3<Int32>>()
    // Depth keyframes and high-resolution stills (main thread only):
    private var depthPolicy = DepthKeyframePolicy()
    private var depthEncoding = false
    private var depthQueued = 0
    private let highResPolicy = HighResPolicy()
    private var highResInFlight = false
    private var highResSupported = true
    private var lastHighResRequest: TimeInterval?
    // encodeQueue only:
    private var photos: [LidarManifest.Photo] = []
    private var depthFrames: [LidarManifest.DepthFrame] = []
    private var acceptingWrites = true

    init(folder: URL) {
        self.folder = folder
        super.init()
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
    }

    /// Starts tracking and LiDAR meshing on the preview's session, and RoomPlan beside it where supported.
    @MainActor
    func attach(to session: ARSession, overlay: CoverageOverlay? = nil) {
        self.session = session
        self.overlay = overlay
        if RoomPlanRecorder.isSupported {
            // RoomPlan runs the session; mesh and depth are added to its configuration in `ensureMeshAndDepth`.
            let recorder = RoomPlanRecorder(arSession: session)
            roomRecorder = recorder
            roomPlanActive = true
            recorder.start()
        } else {
            session.run(Self.configuration())
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private static func configuration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification
        configuration.environmentTexturing = .none
        // Depth and confidence for every photo, so the Mac can fuse them instead of only using the final mesh.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        return configuration
    }

    /// RoomPlan's own configuration has LiDAR running but hands out no mesh anchors or depth. Adding them to
    /// *its* configuration keeps RoomPlan working, and it may drop them again, so this is checked twice a second.
    /// It never resets tracking: same world, RoomPlan keeps going.
    private func ensureMeshAndDepth() {
        guard let configuration = session?.configuration as? ARWorldTrackingConfiguration else { return }
        let wantsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        let depthOK = !wantsDepth || configuration.frameSemantics.contains(.sceneDepth)
        let meshOK = configuration.sceneReconstruction.contains(.meshWithClassification)
        if meshOK && depthOK { return }
        guard let updated = configuration.copy() as? ARWorldTrackingConfiguration else { return }
        updated.initialWorldMap = nil
        updated.sceneReconstruction.insert(.meshWithClassification)
        if wantsDepth { updated.frameSemantics.insert(.sceneDepth) }
        session?.run(updated, options: [])
    }

    private func stopTicking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit { displayLink?.invalidate() }

    /// Stops the session, waits for any write that is still running, and only then deletes the folder,
    /// so a late photo or the mesh save cannot recreate files after they were removed.
    @MainActor
    func cancel() async {
        guard state != .cancelling else { return }
        state = .cancelling
        stopTicking()
        overlay?.clear()
        roomRecorder?.cancel()
        roomFinishTask?.cancel()
        _ = await roomFinishTask?.value  // RoomBuilder may still be writing sidecars
        session?.pause()
        finishTask?.cancel()
        _ = try? await finishTask?.value  // a running save finishes first; its output is then deleted
        await stopEncoding()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Refuses further photo writes and returns once every queued one has completed or been skipped.
    private func stopEncoding() async {
        // `acceptingWrites` is only touched on `encodeQueue`, so handing `self` to that queue is safe.
        nonisolated(unsafe) let capture = self
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            encodeQueue.async {
                capture.acceptingWrites = false
                done.resume()
            }
        }
    }

    // MARK: Frames

    @objc private func tick() {
        guard state == .capturing, let frame = session?.currentFrame, frame.timestamp != lastFrameTimestamp else { return }
        lastFrameTimestamp = frame.timestamp
        handle(frame)
        if Date().timeIntervalSince(lastEnsure) >= 0.5 {
            lastEnsure = Date()
            ensureMeshAndDepth()
        }
    }

    private func handle(_ frame: ARFrame) {
        let now = frame.timestamp
        let transform = frame.camera.transform
        if startTimestamp == nil { startTimestamp = now }

        updateTriangleCount(frame)
        updateCoverage(frame)
        sampleDiagnostics(frame)

        var tracking = false
        if case .normal = frame.camera.trackingState { tracking = true }
        recordDepthKeyframe(frame, tracking: tracking)

        let candidate = CapturePolicy.Frame(
            transform: transform, time: now, trackingNormal: tracking, sharpness: nil,
            exposureDuration: frame.camera.exposureDuration)
        let buffer = frame.capturedImage
        let decision = policy.evaluate(
            candidate, thermal: Self.thermal, busy: encoding,
            coverageGain: { [self] in coverageGain(of: frame) },
            measureSharpness: { Self.sharpness(of: buffer) }
        )
        quality.record(decision)
        switch decision {
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
        lastPhotoTime = now
        if let shot = coveragePhoto(of: frame) {
            coverage.add(shot)
            coverageVersion += 1
            photoDetail = coverage.percent
        }
        let name = String(format: "photos/%04d.jpg", index)
        encodeQueue.async { [weak self] in
            guard let self else { return }
            if self.acceptingWrites, let jpeg = self.ciContext.jpegRepresentation(
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
        requestHighResolutionStill(
            replacing: name, held: .init(
                transform: transform, width: CVPixelBufferGetWidth(buffer),
                exposureDuration: frame.camera.exposureDuration, trackingNormal: tracking))
    }

    // MARK: Coverage

    private func coveragePhoto(of frame: ARFrame) -> CoveragePhoto? {
        let k = frame.camera.intrinsics, size = frame.camera.imageResolution
        guard size.width > 0, size.height > 0,
              let intrinsics = LidarGeometry.Intrinsics([k[0][0], k[1][1], k[2][0], k[2][1]]) else { return nil }
        var grid: CoveragePhoto.DepthGrid?
        if let data = frame.sceneDepth, let values = Self.floats(data.depthMap) {
            let scaled = intrinsics.scaled(from: (Int(size.width), Int(size.height)), to: (values.width, values.height))
            grid = .init(width: values.width, height: values.height, values: values.data,
                         cameraToWorld: frame.camera.transform, intrinsics: scaled)
        }
        return CoveragePhoto(
            cameraToWorld: frame.camera.transform, intrinsics: intrinsics, width: Int(size.width), height: Int(size.height),
            sharpness: 1, depth: grid)
    }

    /// nil while too little surface is known to judge, so the first photos are never refused.
    /// It also returns nil after 3 s without a photo: the mesh is sampled once a second, so a fast sweep into
    /// new ground can look covered for a moment, and the scan must never go quiet because of that.
    private func coverageGain(of frame: ARFrame) -> Float? {
        guard frame.timestamp - lastPhotoTime < 3, coverage.cellCount > 200, let photo = coveragePhoto(of: frame) else { return nil }
        return coverage.gain(of: photo)
    }

    private func updateCoverage(_ frame: ARFrame) {
        let anchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        let t = frame.camera.transform.columns.3
        overlay?.refresh(anchors: anchors, cameraPosition: SIMD3(t.x, t.y, t.z), coverage: coverage, version: coverageVersion)
        guard Date().timeIntervalSince(lastMeshSample) >= 1 else { return }
        lastMeshSample = Date()
        plateau.update(percent: coverage.percent, at: frame.timestamp)
        let stalled = plateau.isPlateau(at: frame.timestamp)
        if stalled != coveragePlateau { coveragePlateau = stalled }
        guard !meshSampling else { return }

        // Only anchors whose mesh changed are copied and sampled.
        var jobs: [(transform: simd_float4x4, vertices: Data, normals: Data, count: Int)] = []
        for anchor in anchors {
            let geometry = anchor.geometry
            let signature = SIMD2(geometry.vertices.count, geometry.faces.count)
            guard meshSignatures[anchor.identifier] != signature,
                  let vertices = Self.packedFloat3(geometry.vertices), let normals = Self.packedFloat3(geometry.normals),
                  geometry.vertices.count == geometry.normals.count else { continue }
            meshSignatures[anchor.identifier] = signature
            jobs.append((anchor.transform, vertices, normals, geometry.vertices.count))
        }
        guard !jobs.isEmpty else { return }
        meshSampling = true
        coverageQueue.async { [weak self] in
            guard let self else { return }
            var fresh: [CoverageMap.Sample] = []
            for job in jobs {
                let rotation = simd_float3x3(
                    SIMD3(job.transform.columns.0.x, job.transform.columns.0.y, job.transform.columns.0.z),
                    SIMD3(job.transform.columns.1.x, job.transform.columns.1.y, job.transform.columns.1.z),
                    SIMD3(job.transform.columns.2.x, job.transform.columns.2.y, job.transform.columns.2.z))
                job.vertices.withUnsafeBytes { vertexBytes in
                    job.normals.withUnsafeBytes { normalBytes in
                        let v = vertexBytes.bindMemory(to: Float.self), n = normalBytes.bindMemory(to: Float.self)
                        for i in 0..<job.count {
                            let local = SIMD4(v[i * 3], v[i * 3 + 1], v[i * 3 + 2], 1)
                            let world4 = job.transform * local
                            let world = SIMD3(world4.x, world4.y, world4.z)
                            guard self.seenCells.insert(self.keyer.cellKey(world)).inserted else { continue }
                            fresh.append(.init(position: world, normal: rotation * SIMD3(n[i * 3], n[i * 3 + 1], n[i * 3 + 2])))
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.meshSampling = false
                guard self.state == .capturing, !fresh.isEmpty else { return }
                self.coverage.integrate(fresh)
                self.coverageVersion += 1
                self.photoDetail = self.coverage.percent
            }
        }
    }

    /// Tightly packed copy of a float3 geometry source (ARKit's buffers can have a larger stride).
    private static func packedFloat3(_ source: ARGeometrySource) -> Data? {
        guard source.format == .float3, source.count > 0 else { return nil }
        var data = Data(capacity: source.count * 12)
        let base = source.buffer.contents().advanced(by: source.offset)
        for i in 0..<source.count { data.append(Data(bytes: base.advanced(by: i * source.stride), count: 12)) }
        return data
    }

    /// Depth map as Float32 meters, row by row without padding.
    private static func floats(_ buffer: CVPixelBuffer) -> (data: [Float], width: Int, height: Int)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, stride >= width * 4 else { return nil }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<width { out[y * width + x] = row[x].isFinite ? row[x] : 0 }
        }
        return (out, width, height)
    }

    // MARK: Depth keyframes

    /// Keeps this frame's depth as a keyframe with its own pose, several times a second while moving.
    private func recordDepthKeyframe(_ frame: ARFrame, tracking: Bool) {
        guard depthPolicy.shouldTake(
            time: frame.timestamp, transform: frame.camera.transform, trackingNormal: tracking,
            thermal: Self.thermal, busy: depthEncoding),
            let copy = Self.copyDepthHalf(frame) else { return }
        depthEncoding = true
        depthQueued += 1
        let index = depthQueued
        let k = frame.camera.intrinsics, size = frame.camera.imageResolution
        let seconds = frame.timestamp - (startTimestamp ?? frame.timestamp)
        let flat = Self.flatten(frame.camera.transform)
        let scaled = LidarGeometry.Intrinsics([k[0][0], k[1][1], k[2][0], k[2][1]])?
            .scaled(from: (Int(size.width), Int(size.height)), to: (copy.width, copy.height))
        encodeQueue.async { [weak self] in
            guard let self else { return }
            var saved: LidarManifest.DepthFrame?
            if self.acceptingWrites, let scaled {
                let directory = self.folder.appendingPathComponent("depth")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let depthName = String(format: "depth/f%05d.depth", index), confName = String(format: "depth/f%05d.conf", index)
                do {
                    try copy.depth.write(to: self.folder.appendingPathComponent(depthName), options: .atomic)
                    try copy.confidence.write(to: self.folder.appendingPathComponent(confName), options: .atomic)
                    saved = LidarManifest.DepthFrame(
                        file: depthName, confidenceFile: confName, width: copy.width, height: copy.height, encoding: .float16,
                        timestamp: seconds, transform: flat, intrinsics: scaled.array, smoothed: copy.smoothed)
                } catch {
                    try? FileManager.default.removeItem(at: self.folder.appendingPathComponent(depthName))
                    try? FileManager.default.removeItem(at: self.folder.appendingPathComponent(confName))
                }
            }
            if let saved { self.depthFrames.append(saved) }
            let count = self.depthFrames.count
            DispatchQueue.main.async {
                self.depthFrameCount = count
                self.depthEncoding = false
            }
        }
    }

    /// Like `copyDepth`, but the depth is Float16 (half the bytes; LiDAR noise is far above the rounding).
    private static func copyDepthHalf(_ frame: ARFrame) -> DepthCopy? {
        guard let data = frame.sceneDepth, let confidence = data.confidenceMap,
              let depth = floats(data.depthMap), let conf = packed(confidence, bytesPerPixel: 1),
              depth.width == conf.width, depth.height == conf.height else { return nil }
        let half = depth.data.map { Float16($0) }
        let bytes = half.withUnsafeBufferPointer { Data(buffer: $0) }
        return DepthCopy(depth: bytes, confidence: conf.data, width: depth.width, height: depth.height, smoothed: false)
    }

    // MARK: High-resolution stills

    /// Asks ARKit for a full-resolution still and, if it shows the same view with no more blur, swaps it in for
    /// the video frame that was just saved as `name`. Rare and only on a cool phone (see `HighResPolicy`).
    private func requestHighResolutionStill(replacing name: String, held: HighResPolicy.View) {
        let now = ProcessInfo.processInfo.systemUptime
        guard highResPolicy.shouldRequest(
            now: now, lastRequest: lastHighResRequest, thermal: Self.thermal, inFlight: highResInFlight,
            budgetConstrained: false, supported: highResSupported) else { return }
        highResInFlight = true
        lastHighResRequest = now
        session?.captureHighResolutionFrame { [weak self] frame, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.highResInFlight = false
                if error != nil { self.highResSupported = false; return }  // do not keep asking
                guard self.state == .capturing, let frame else { return }
                var normal = false
                if case .normal = frame.camera.trackingState { normal = true }
                let still = HighResPolicy.View(
                    transform: frame.camera.transform, width: CVPixelBufferGetWidth(frame.capturedImage),
                    exposureDuration: frame.camera.exposureDuration, trackingNormal: normal)
                guard self.highResPolicy.accepts(still: still, replacing: held) else { return }
                self.swapInStill(frame, for: name)
            }
        }
    }

    /// Longest edge of a saved still. Full-resolution frames are scaled down to this.
    private static let maximumStillEdge = 3024

    private func swapInStill(_ frame: ARFrame, for name: String) {
        let buffer = frame.capturedImage
        let intrinsics = frame.camera.intrinsics
        let flat = Self.flatten(frame.camera.transform)
        let exposure = LidarManifest.Exposure(
            duration: frame.camera.exposureDuration, offset: frame.camera.exposureOffset,
            ambientIntensity: frame.lightEstimate.map { Float($0.ambientIntensity) })
        encodeQueue.async { [weak self] in
            guard let self, self.acceptingWrites, let i = self.photos.firstIndex(where: { $0.file == name }) else { return }
            let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
            let scale = min(1, CGFloat(Self.maximumStillEdge) / CGFloat(max(sourceWidth, sourceHeight)))
            var image = CIImage(cvPixelBuffer: buffer)
            if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            let width = Int(image.extent.width.rounded()), height = Int(image.extent.height.rounded())
            guard width > 0, height > 0,
                  let jpeg = self.ciContext.jpegRepresentation(
                    of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]),
                  (try? jpeg.write(to: self.folder.appendingPathComponent(name), options: .atomic)) != nil,
                  let k = LidarGeometry.Intrinsics([intrinsics[0][0], intrinsics[1][1], intrinsics[2][0], intrinsics[2][1]])?
                    .scaled(from: (sourceWidth, sourceHeight), to: (width, height)) else { return }
            // Keep the video depth's original pose before changing the photo to the still's view.
            // The photo timestamp stays in capture order; depth has its own original timestamp.
            var photo = self.photos[i]
            if let depth = photo.detachDepthFrame() { self.depthFrames.append(depth) }
            photo.width = width; photo.height = height
            photo.transform = flat; photo.intrinsics = k.array
            photo.exposure = exposure; photo.highRes = true
            self.photos[i] = photo
            let total = self.photos.filter { $0.highRes == true }.count
            DispatchQueue.main.async { self.highResCount = total }
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
        guard session?.currentFrame != nil else { throw Failure.noFrame }
        state = .finishing
        stopTicking()
        overlay?.clear()
        // RoomPlan first: it keeps the ARSession running, so the mesh below still includes everything.
        let folder = self.folder
        let roomTask = Task { @MainActor [roomRecorder] in await roomRecorder?.finish(into: folder) }
        roomFinishTask = roomTask
        let room = await roomTask.value
        roomFinishTask = nil
        guard state == .finishing else { throw CancellationError() }  // cancelled while RoomPlan was building
        guard let frame = session?.currentFrame else { state = .failed(Failure.noFrame.localizedDescription); throw Failure.noFrame }
        // ARKit may keep changing its mesh buffers, so copy them now; everything after works on the copies.
        let chunks = Self.snapshot(frame.anchors.compactMap { $0 as? ARMeshAnchor })
        session?.pause()
        let task = Task.detached(priority: .userInitiated) { [self] () -> Result in
            let recorded = await self.drainRecording()  // waits for photos and depth still being written
            try Task.checkCancellation()
            let meshDirectory = folder.appendingPathComponent("mesh")
            try FileManager.default.createDirectory(at: meshDirectory, withIntermediateDirectories: true)
            let summary = try Diagnostics.measure("lidar.writeMesh") {
                try PLYWriter.write(chunks: chunks, to: meshDirectory.appendingPathComponent("scan.ply"))
            }
            try Task.checkCancellation()
            let manifest = try Self.validated(LidarManifest(
                createdAt: Date(), device: device, vertexCount: summary.vertexCount,
                triangleCount: summary.triangleCount, photos: recorded.photos,
                depthFrames: recorded.depthFrames, room: room), in: folder)
            try CaptureManifest.encoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            return Result(folder: folder, photos: recorded.photos.count, triangles: summary.triangleCount)
        }
        finishTask = task
        do {
            let result = try await task.value
            if state == .finishing {
                state = .saved
                var snapshot = qualitySnapshot
                snapshot.photoCount = result.photos
                try? ScanQualityFiles.save(snapshot, named: ScanQualityFiles.snapshotName, folder: folder)
            }
            return result
        } catch {
            // Keep the photos, drop the half-made mesh so nothing looks like a finished scan.
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("mesh"))
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("manifest.json"))
            if state == .finishing { state = .failed(error.localizedDescription) }
            throw error
        }
    }

    /// A bundle must pass `LidarBundleValidator` before it is declared complete. Depth, depth keyframes and the
    /// room layout that fail (missing or misaligned) are dropped, because the photos and the mesh are still
    /// good; anything else that fails stops the save with the reason, rather than shipping a bundle the Mac
    /// cannot trust.
    static func validated(_ manifest: LidarManifest, in folder: URL) throws -> LidarManifest {
        var manifest = manifest
        let issues = LidarBundleValidator.validate(manifest: manifest, in: folder)
        guard !issues.isEmpty else { return manifest }
        let bad = Set(issues.compactMap(\.photo))
        func remove(_ path: String) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(path)) }
        for i in manifest.photos.indices where bad.contains(manifest.photos[i].file) && manifest.photos[i].depth != nil {
            if let depth = manifest.photos[i].depth { remove(depth.file); remove(depth.confidenceFile) }
            manifest.photos[i].depth = nil
        }
        var frames = manifest.depthFrames ?? []
        for frame in frames where bad.contains(frame.file) { remove(frame.file); remove(frame.confidenceFile) }
        frames.removeAll { bad.contains($0.file) }
        var room = manifest.room
        if let layout = room, bad.contains(layout.file) {
            remove("room")
            room = nil
        }
        // Rebuild so format and capabilities follow what is actually in the bundle.
        let rebuilt = LidarManifest(
            createdAt: manifest.createdAt, device: manifest.device, vertexCount: manifest.vertexCount,
            triangleCount: manifest.triangleCount, photos: manifest.photos, depthFrames: frames, room: room)
        let remaining = LidarBundleValidator.validate(manifest: rebuilt, in: folder)
        if let first = remaining.first { throw Failure.invalidBundle(first.description) }
        return rebuilt
    }

    private func drainRecording() async -> (photos: [LidarManifest.Photo], depthFrames: [LidarManifest.DepthFrame]) {
        // `photos` and `depthFrames` are only touched on `encodeQueue`, so handing `self` to that queue is safe.
        nonisolated(unsafe) let capture = self
        return await withCheckedContinuation { (done: CheckedContinuation<(photos: [LidarManifest.Photo], depthFrames: [LidarManifest.DepthFrame]), Never>) in
            encodeQueue.async {
                done.resume(returning: (capture.photos, capture.depthFrames.sorted { $0.timestamp < $1.timestamp }))
            }
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
        // The mesh is drawn by `CoverageOverlay` in coverage colors instead of ARKit's own debug overlay.
        capture.attach(to: view.session, overlay: CoverageOverlay(view: view))
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) { uiView.session.pause() }
}
#endif
