#if os(iOS)
import CaptureKit
import Foundation
import ScanLink
import SwiftUI
import UIKit

/// App-level state. Logic that can be tested without a device lives in CaptureKit.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case needsPairing
        case ready
        case capturing
        case choosing(folder: URL)
        case lidarCapturing
        /// A finished LiDAR scan waiting to be sent. Its details are in `pendingLidar`.
        case lidarReady
        case reconstructing(Double?)
        case submitting(done: Int, total: Int)
        case submitted(jobId: String, photos: Int)
        case sendingToMac(name: String)
        case sentToMac(name: String)
        /// The model built on this phone, shown in AR Quick Look before anything is sent.
        case viewing(folder: URL, model: URL)
        case failed(String)
    }

    @Published var phase: Phase
    /// A link waiting for the user to confirm its server. Nothing is stored until they do.
    @Published var pendingLink: PairingLink?
    @Published var showNearbyMac = false
    @Published private(set) var pairedMac: PairedMac?
    @Published private(set) var pendingCapture: URL?
    /// A finished LiDAR scan that has not reached the Mac yet. Backed by the scan catalog, so it is
    /// recovered after an app restart like Object Capture scans.
    @Published private(set) var pendingLidar: PendingLidar?
    /// The catalog record of the LiDAR scan being captured right now.
    @Published private(set) var activeLidarId: UUID?

    struct PendingLidar: Equatable {
        let id: UUID
        let folder: URL
        let photos: Int
        let triangles: Int
    }
    let catalog = ScanCatalog.standard()
    var activeLidarFolder: URL? { activeLidarId.flatMap { catalog.record(id: $0) }.map { catalog.folderURL($0) } }
    /// Scans that cannot be sent (the app stopped mid-write). Kept on disk until the user discards them.
    var unfinishedScans: [ScanRecord] { catalog.all.filter { $0.status == .incomplete } }

    func discardUnfinishedScans() {
        for record in unfinishedScans { try? catalog.discard(id: record.id) }
        objectWillChange.send()
    }
    var pairedHost: String? { pairing?.server.host }
    var isPaired: Bool { pairing != nil || pairedMac != nil }
    private let pairingStore = KeychainPairingStore()
    private let macStore = KeychainMacStore()
    private var pairing: PairingLink?
    private let captureStore = PendingCaptureStore()

    init() {
        let link = pairingStore.load()
        let mac = macStore.load()
        pairing = link
        pairedMac = mac
        let folder = captureStore.load()
        pendingCapture = folder
        // Settle what a crash or force-quit left behind: complete scans become retryable, torn ones are
        // marked incomplete (never deleted automatically), and delivered scans past retention are removed.
        _ = try? catalog.reconcile()
        _ = try? catalog.pruneDelivered()
        let lidar = Self.latestLidar(in: catalog)
        pendingLidar = lidar
        if let folder {
            phase = .choosing(folder: folder)
        } else if lidar != nil {
            phase = .lidarReady
        } else {
            phase = (link == nil && mac == nil) ? .needsPairing : .ready
        }
    }

    private static func latestLidar(in catalog: ScanCatalog) -> PendingLidar? {
        guard let r = catalog.all.first(where: { $0.kind == .lidar && $0.isRecoverable }) else { return nil }
        return PendingLidar(id: r.id, folder: catalog.folderURL(r), photos: r.photoCount, triangles: r.triangleCount)
    }

    /// Called for deep links and pasted text. Never pairs on its own: a crafted link must not be
    /// able to point the app (and the photos it uploads) at someone else's server.
    func receive(url: URL) {
        guard let link = PairingLink(url: url) else {
            phase = .failed("That is not a valid pairing link.")
            return
        }
        pendingLink = link
    }

    func confirmPending() {
        guard let link = pendingLink else { return }
        pendingLink = nil
        do {
            try pairingStore.save(link)
            pairing = link
            recoverCapture()
        } catch {
            phase = .failed("Could not store the pairing: \(error.localizedDescription)")
        }
    }

    func rejectPending() { pendingLink = nil }

    func unpair() {
        pairingStore.clear()
        pairing = nil
        recoverCapture()
    }

    // MARK: Nearby Mac (local network)

    /// Called after the user entered a code. Checks that the address is a 3lay Mac receiver and
    /// that the code is right before anything is stored, so a typo is caught here and not
    /// halfway through an upload.
    func pairMac(endpoint: LanEndpoint, code: String) async throws {
        let client = LanClient(endpoint: endpoint, code: code)
        let hello = try await client.hello()
        try await client.verifyCode()
        // A typed address has no Bonjour name yet, so take the one the Mac reports about itself.
        let name = endpoint.name == endpoint.host ? hello.name : endpoint.name
        let mac = PairedMac(name: name, host: endpoint.host, port: endpoint.port, code: code)
        try macStore.save(mac)
        pairedMac = mac
        showNearbyMac = false
        if phase == .needsPairing { phase = .ready }
    }

    func forgetMac() {
        macStore.clear()
        pairedMac = nil
        recoverCapture()
    }

    /// The Mac's current address. Tries the last known one first, then looks the Mac up by
    /// its Bonjour name, because a router can hand it a different IP address after a restart.
    private func reachableClient(for mac: PairedMac) async throws -> LanClient {
        let saved = LanEndpoint(name: mac.name, host: mac.host, port: mac.port)
        let client = LanClient(endpoint: saved, code: mac.code)
        if (try? await client.hello()) != nil { return client }
        guard let found = await MacBrowser.find(name: mac.name),
            let endpoint = try? await MacBrowser.resolve(found)
        else { throw LanError.unreachable("\(mac.name) was not found on this Wi-Fi network. Is 3lay Mac open?") }
        let updated = PairedMac(name: mac.name, host: endpoint.host, port: endpoint.port, code: mac.code)
        try? macStore.save(updated)
        pairedMac = updated
        return LanClient(endpoint: endpoint, code: mac.code)
    }

    /// Builds the model on the phone (reduced detail) and opens it so you can look at it before sending.
    /// The USDZ stays in the capture folder, so "Send to Mac" from the viewer does not build it twice.
    func buildAndPreview(folder: URL) async {
        let model = folder.appendingPathComponent("model.usdz")
        do {
            if !FileManager.default.fileExists(atPath: model.path) {
                phase = .reconstructing(nil)
                try await OnDeviceReconstruction.run(
                    imagesDirectory: folder.appendingPathComponent("Images"), output: model,
                    progress: { fraction in Task { @MainActor in self.reconstructionProgress(fraction) } })
            }
            phase = .viewing(folder: folder, model: model)
        } catch {
            phase = .failed("\(error.localizedDescription) Your scan is kept on this phone.")
        }
    }

    /// Reconstructs on the phone, then sends the USDZ to the paired Mac. 3lay Mac converts it to STL.
    func sendToMac(folder: URL, name: String) async {
        guard let mac = pairedMac else { showNearbyMac = true; return }
        let model = folder.appendingPathComponent("model.usdz")
        do {
            // Check the Mac first: a minute of reconstruction is wasted if it is not there.
            phase = .sendingToMac(name: mac.name)
            let client = try await reachableClient(for: mac)
            // A stale code is reported clearly here. Failing mid-upload only shows a dropped connection.
            try await client.verifyCode()
            if !FileManager.default.fileExists(atPath: model.path) {
                phase = .reconstructing(nil)
                try await OnDeviceReconstruction.run(
                    imagesDirectory: folder.appendingPathComponent("Images"), output: model,
                    progress: { fraction in Task { @MainActor in self.reconstructionProgress(fraction) } })
                phase = .sendingToMac(name: mac.name)
            }
            try await client.upload(file: model, as: Self.macFilename(name))
            clearPendingCapture()
            phase = .sentToMac(name: mac.name)
        } catch LanError.wrongCode, LanError.lockedOut {
            phase = .failed("\(mac.name) did not accept the code. If you made a new code on the Mac, "
                + "open Nearby Mac and enter it again. Your scan is kept on this phone.")
        } catch let error as OnDeviceError {
            // Reconstruction failed before anything was sent, so don't blame the Mac or the network.
            phase = .failed("\(error.localizedDescription) Your scan is kept on this phone.")
        } catch {
            phase = .failed("Could not send to \(mac.name): \(error.localizedDescription) Your scan is kept on this phone.")
        }
    }

    /// Sends the photos and lets the Mac build the model. Quicker for the phone and more detailed
    /// than building on the phone. Falls back to a clear message on a Mac that cannot do this yet.
    func sendPhotosToMac(folder: URL, name: String) async {
        guard let mac = pairedMac else { showNearbyMac = true; return }
        var archive: URL?
        defer { archive.map { try? FileManager.default.removeItem(at: $0) } }
        do {
            phase = .sendingToMac(name: mac.name)
            let client = try await reachableClient(for: mac)
            try await client.verifyCode()
            guard let limit = try await client.hello().maxCaptureBytes else {
                phase = .failed("\(mac.name) runs an older 3lay Mac that cannot build from photos. "
                    + "Update it, or choose Build on this phone. Your scan is kept on this phone.")
                return
            }
            let zip = try await Self.pack(
                imagesDirectory: folder.appendingPathComponent("Images"),
                name: Self.macFilename(name).replacingOccurrences(of: ".usdz", with: ""))
            archive = zip
            let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
            if size > limit { throw LanError.tooLarge(maxBytes: limit) }
            try await client.upload(file: zip)
            clearPendingCapture()
            phase = .sentToMac(name: mac.name)
        } catch LanError.wrongCode, LanError.lockedOut {
            phase = .failed("\(mac.name) did not accept the code. If you made a new code on the Mac, "
                + "open Nearby Mac and enter it again. Your scan is kept on this phone.")
        } catch {
            phase = .failed("Could not send to \(mac.name): \(error.localizedDescription) Your scan is kept on this phone.")
        }
    }

    // MARK: LiDAR mode (rooms and large objects)

    /// Needs a paired Mac first: a LiDAR scan has nowhere else to go (the server cannot use it).
    func beginLidarCapture() {
        guard pairedMac != nil else { showNearbyMac = true; return }
        let folder = catalog.root.appendingPathComponent("lidar-captures/\(UUID().uuidString)", isDirectory: true)
        let record = ScanRecord(kind: .lidar, name: "LiDAR scan", status: .capturing, folder: catalog.relativePath(of: folder))
        do {
            try catalog.upsert(record)
        } catch {
            phase = .failed("Could not start a scan: \(error.localizedDescription)")
            return
        }
        activeLidarId = record.id
        phase = .lidarCapturing
    }

    /// Finish was pressed: from here a crash leaves a `saving` record that recovery can sort out.
    func lidarCaptureSaving() {
        guard let id = activeLidarId else { return }
        try? catalog.update(id: id) { $0.status = .saving }
    }

    func lidarCaptureFinished(folder: URL, photos: Int, triangles: Int) {
        guard let id = activeLidarId else { return }
        try? catalog.update(id: id) { $0.status = .saved; $0.photoCount = photos; $0.triangleCount = triangles; $0.lastError = nil }
        pendingLidar = PendingLidar(id: id, folder: folder, photos: photos, triangles: triangles)
        activeLidarId = nil
        phase = .lidarReady
    }

    /// Saving failed. The photos stay on disk, the record becomes `incomplete`: it is not offered for
    /// sending, and shows up for discarding after a relaunch.
    func lidarCaptureFailed(_ message: String) {
        guard let id = activeLidarId else { return }
        try? catalog.update(id: id) { $0.status = .incomplete; $0.lastError = message }
    }

    /// The capture screen already deleted the files. Drop the record and go back.
    func lidarCaptureCancelled() {
        if let id = activeLidarId { try? catalog.remove(id: id) }
        activeLidarId = nil
        phase = isPaired ? .ready : .needsPairing
    }

    func discardLidar() {
        if let id = pendingLidar?.id { try? catalog.discard(id: id) }
        pendingLidar = Self.latestLidar(in: catalog)
        phase = pendingLidar != nil ? .lidarReady : (isPaired ? .ready : .needsPairing)
    }

    /// Zips the LiDAR bundle as `<name>.lidar.zip` and sends it. 3lay Mac imports the mesh as is.
    func sendLidarToMac(name: String) async {
        guard let mac = pairedMac, let pending = pendingLidar else { showNearbyMac = true; return }
        var archive: URL?
        defer { archive.map { try? FileManager.default.removeItem(at: $0) } }
        try? catalog.update(id: pending.id) { $0.status = .sending; $0.destination = mac.name }
        do {
            phase = .sendingToMac(name: mac.name)
            let client = try await reachableClient(for: mac)
            try await client.verifyCode()
            let hello = try await client.hello()
            guard hello.supportsLidarBundles == true, let limit = hello.maxCaptureBytes else {
                markLidarFailed(pending.id, "The Mac is too old to import LiDAR scans.")
                phase = .failed("\(mac.name) runs an older 3lay Mac that cannot import LiDAR scans. "
                    + "Update it first. Your scan is kept on this phone.")
                return
            }
            let zip = try await Self.pack(
                imagesDirectory: pending.folder,
                name: Self.macFilename(name).replacingOccurrences(of: ".usdz", with: "") + ".lidar")
            archive = zip
            let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
            if size > limit { throw LanError.tooLarge(maxBytes: limit) }
            try await client.upload(file: zip)
            try? catalog.discard(id: pending.id)  // delivered: LiDAR sources are not kept
            pendingLidar = Self.latestLidar(in: catalog)
            phase = .sentToMac(name: mac.name)
        } catch LanError.wrongCode, LanError.lockedOut {
            markLidarFailed(pending.id, "The Mac did not accept the code.")
            phase = .failed("\(mac.name) did not accept the code. If you made a new code on the Mac, "
                + "open Nearby Mac and enter it again. Your scan is kept on this phone.")
        } catch {
            markLidarFailed(pending.id, error.localizedDescription)
            phase = .failed("Could not send to \(mac.name): \(error.localizedDescription) Your scan is kept on this phone.")
        }
    }

    private func markLidarFailed(_ id: UUID, _ message: String) {
        try? catalog.update(id: id) { $0.status = .failed; $0.lastError = message }
    }

    // MARK: Progress

    /// Progress arrives from background tasks, possibly late or out of order. Apply it only while that
    /// step is still showing (a late callback used to overwrite the next screen), only when it moves
    /// forward, and only per whole percent, so the view is not rebuilt on every tiny change.
    private func reconstructionProgress(_ fraction: Double) {
        guard case .reconstructing(let old) = phase else { return }
        if let old, Int(fraction * 100) <= Int(old * 100) { return }
        phase = .reconstructing(fraction)
    }

    private func uploadProgress(done: Int, total: Int) {
        guard case .submitting(let old, _) = phase, done > old else { return }
        phase = .submitting(done: done, total: total)
    }

    /// Zipping hundreds of photos is slow, synchronous file work. Run on the main actor it froze the UI.
    nonisolated private static func pack(imagesDirectory: URL, name: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try Diagnostics.measure("archive.make") { try CaptureArchive.make(imagesDirectory: imagesDirectory, name: name) }
        }.value
    }

    static func macFilename(_ name: String, now: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }.trimmingCharacters(in: .whitespaces)
        return "\(safe.isEmpty ? "Scan" : safe) \(stamp).usdz"
    }

    /// The catalog record for an Object Capture folder, created on first use (also for scans saved
    /// before the catalog existed).
    private func objectRecord(for folder: URL) -> ScanRecord {
        let path = catalog.relativePath(of: folder)
        if let existing = catalog.all.first(where: { $0.kind == .object && $0.folder == path }) { return existing }
        let record = ScanRecord(kind: .object, name: "Scan", status: .saved, folder: path)
        try? catalog.upsert(record)
        return record
    }

    func captureFinished(folder: URL) {
        _ = objectRecord(for: folder)
        pendingCapture = folder
        do {
            try captureStore.save(folder: folder)
            phase = .choosing(folder: folder)
        } catch {
            phase = .failed("Could not save capture recovery information: \(error.localizedDescription)")
        }
    }

    func recoverCapture() {
        if let folder = pendingCapture { phase = .choosing(folder: folder) }
        else if let lidar = Self.latestLidar(in: catalog) { pendingLidar = lidar; phase = .lidarReady }
        else { phase = isPaired ? .ready : .needsPairing }
    }

    /// Leaves the "Capture complete" screen but keeps the scan, so "Resume saved capture" can reopen it.
    func leaveCapture() {
        phase = isPaired ? .ready : .needsPairing
    }

    /// Deletes the unsent scan for good. Callers must have asked the user first.
    func discardCapture() {
        if let folder = pendingCapture {
            try? catalog.discard(id: objectRecord(for: folder).id)  // removes the files and the record
            try? FileManager.default.removeItem(at: folder)
        }
        // Not clearPendingCapture(): that would mark the (now deleted) scan as delivered.
        try? captureStore.clear()
        pendingCapture = nil
        phase = isPaired ? .ready : .needsPairing
    }

    private func clearPendingCapture() {
        if let folder = pendingCapture {
            // Delivered: kept on disk for the retention period, then removed by `pruneDelivered`.
            let record = objectRecord(for: folder)
            try? catalog.update(id: record.id) { $0.status = .sent }
        }
        try? captureStore.clear()
        pendingCapture = nil
    }
    func beginCapture() { phase = .capturing }
    func cancelCapture() { phase = .ready }

    static var device: CaptureManifest.Device {
        CaptureManifest.Device(
            model: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            hasLiDAR: ObjectCaptureAvailability.isSupported)
    }

    func submit(imagesDirectory: URL, name: String) async {
        guard let pairing else { phase = .needsPairing; return }
        let api = APIClient(transport: URLSessionTransport(baseURL: pairing.server, token: pairing.token))
        let store = FileUploadStore()
        let submission = Submission(api: api, uploader: ResumableUploader(api: api, store: store))
        phase = .submitting(done: 0, total: 1)
        // The scan's folder is the Images folder's parent; its record remembers the job across retries.
        let record = objectRecord(for: imagesDirectory.deletingLastPathComponent())
        do {
            let result = try await submission.submit(
                name: name, imagesDirectory: imagesDirectory, device: Self.device,
                jobId: record.serverJobId,
                onJobCreated: { id in
                    await MainActor.run { try? self.catalog.update(id: record.id) { $0.serverJobId = id; $0.destination = pairing.server.host } }
                },
                onProgress: { done, total in
                    Task { @MainActor in self.uploadProgress(done: done, total: total) }
                })
            phase = .submitted(jobId: result.jobId, photos: result.photoCount)
            clearPendingCapture()
        } catch {
            phase = .failed("Upload failed: \(error). Your photos are kept, try again to resume.")
        }
    }

    /// Reconstructs on the phone and uploads the mesh. No Mac needed, but lower detail.
    func submitOnDevice(folder: URL, name: String) async {
        guard let pairing else { phase = .needsPairing; return }
        phase = .reconstructing(nil)
        let model = folder.appendingPathComponent("model.usdz")
        do {
            try await OnDeviceReconstruction.run(
                imagesDirectory: folder.appendingPathComponent("Images"), output: model,
                progress: { fraction in Task { @MainActor in self.reconstructionProgress(fraction) } })
            let api = APIClient(transport: URLSessionTransport(baseURL: pairing.server, token: pairing.token))
            let uploader = ResumableUploader(api: api, store: FileUploadStore())
            let job = try await api.createJob(name: name, sourceKind: "mesh")
            phase = .submitting(done: 0, total: 1)
            _ = try await uploader.upload(file: model, jobId: job.id, kind: "original")
            phase = .submitted(jobId: job.id, photos: 0)
            clearPendingCapture()
        } catch {
            phase = .failed("On-device reconstruction failed: \(error)")
        }
    }
}
#endif
