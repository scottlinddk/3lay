#if os(iOS)
import Combine
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
        /// A long operation is running. What it is doing, and how far, is in `operations.current`.
        case working
        case submitted(jobId: String, photos: Int)
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
    /// The one running operation (saving, packing, sending, building). See `OperationTracker`.
    let operations = OperationTracker()
    private var completion: Completion?
    /// Set by a finished server submission so its success screen can show the job.
    private var submittedJob: (jobId: String, photos: Int)?
    private var outcomeObserver: AnyCancellable?

    /// What to do when the running operation ends. Set when it starts, used once.
    private struct Completion {
        let success: (String) -> Void
        let failure: (String) -> Void
        let cancelled: () -> Void
    }
    var activeLidarFolder: URL? { activeLidarId.flatMap { catalog.record(id: $0) }.map { catalog.folderURL($0) } }
    /// Every scan the app holds, newest first. Read fresh each time the home screen is drawn.
    var scans: [ScanRecord] { catalog.all }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? catalog.update(id: id) { $0.name = trimmed }
    }

    /// Opens a scan from the list on its review screen.
    func open(_ record: ScanRecord) {
        let folder = catalog.folderURL(record)
        switch record.kind {
        case .object:
            pendingCapture = folder
            // A delivered scan is only kept for re-sending; it must not come back as "unsent" after a relaunch.
            if record.status != .sent { try? captureStore.save(folder: folder) }
            phase = .choosing(folder: folder)
        case .lidar:
            pendingLidar = PendingLidar(id: record.id, folder: folder, photos: record.photoCount, triangles: record.triangleCount)
            phase = .lidarReady
        }
    }

    func delete(_ record: ScanRecord) {
        let folder = catalog.folderURL(record)
        if record.kind == .object, pendingCapture?.standardizedFileURL == folder.standardizedFileURL {
            try? captureStore.clear()
            pendingCapture = nil
        }
        try? catalog.discard(id: record.id)
        if pendingLidar?.id == record.id { pendingLidar = Self.latestLidar(in: catalog) }
        objectWillChange.send()
    }

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
        outcomeObserver = operations.$outcome.compactMap { $0 }.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.finishOperation($0) }
    }

    // MARK: Operations

    struct OperationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Starts `work` under the tracker and shows the progress screen. A second start while one runs is
    /// ignored. `work` runs off the main actor; it throws, and `describe` turns the error into the
    /// message shown to the user.
    private func run(
        title: String, scanId: UUID? = nil, destination: String? = nil,
        success: @escaping (String) -> Void, cancelled: @escaping () -> Void,
        failure: @escaping (String) -> Void = { _ in },
        work: @escaping @Sendable (OperationTracker.Context) async throws -> String
    ) {
        guard !operations.isRunning else { return }
        completion = Completion(
            success: success, failure: { [weak self] message in
                failure(message)
                self?.phase = .failed(message)
            }, cancelled: cancelled)
        let started = operations.start(title: title, scanId: scanId) { context in
            do { return try await work(context) } catch is CancellationError { throw CancellationError() } catch {
                throw OperationError(message: Self.describe(error, destination: destination))
            }
        }
        if started { phase = .working } else { completion = nil }
    }

    private func finishOperation(_ outcome: OperationOutcome) {
        let handler = completion
        completion = nil
        operations.acknowledgeOutcome()
        switch outcome {
        case .succeeded(let message): handler?.success(message)
        case .failed(let message): handler?.failure(message)
        case .cancelled: handler?.cancelled()
        }
    }

    /// Cancel from the progress screen. The scan stays on the phone and can be sent again.
    func cancelOperation() { operations.cancel() }

    /// One place that words failures, so every flow says the same thing.
    nonisolated static func describe(_ error: Error, destination: String?) -> String {
        let kept = "Your scan is kept on this phone."
        switch error {
        case LanError.wrongCode, LanError.lockedOut:
            return "\(destination ?? "The Mac") did not accept the code. If you made a new code on the Mac, "
                + "open Nearby Mac and enter it again. \(kept)"
        case let error as OnDeviceError:
            // Reconstruction failed before anything was sent, so don't blame the Mac or the network.
            return "\(error.localizedDescription) \(kept)"
        case let error as OperationError:
            return "\(error.message) \(kept)"
        default:
            if let destination { return "Could not send to \(destination): \(error.localizedDescription) \(kept)" }
            return "\(error.localizedDescription) \(kept)"
        }
    }

    /// Returns to the right screen after a cancel, without touching the scan.
    private func backAfterCancel() { recoverCapture() }

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
    func buildAndPreview(folder: URL) {
        let model = folder.appendingPathComponent("model.usdz")
        if FileManager.default.fileExists(atPath: model.path) { phase = .viewing(folder: folder, model: model); return }
        run(title: "Build preview", success: { [weak self] _ in self?.phase = .viewing(folder: folder, model: model) },
            cancelled: { [weak self] in self?.backAfterCancel() }) { context in
            context.update(.reconstructing(fraction: nil))
            try await Self.buildModel(folder: folder, output: model, context: context)
            return "Preview ready"
        }
    }

    /// Reconstructs on the phone, then sends the USDZ to the paired Mac. 3lay Mac converts it to STL.
    func sendToMac(folder: URL, name: String) {
        guard let mac = pairedMac else { showNearbyMac = true; return }
        let model = folder.appendingPathComponent("model.usdz")
        run(title: "Send to \(mac.name)", destination: mac.name,
            success: { [weak self] _ in self?.clearPendingCapture(); self?.phase = .sentToMac(name: mac.name) },
            cancelled: { [weak self] in self?.backAfterCancel() }) { [self] context in
            // Check the Mac first: a minute of reconstruction is wasted if it is not there.
            context.update(.preparing)
            let client = try await self.reachableClient(for: mac)
            // A stale code is reported clearly here. Failing mid-upload only shows a dropped connection.
            try await client.verifyCode()
            if !FileManager.default.fileExists(atPath: model.path) {
                context.update(.reconstructing(fraction: nil))
                try await Self.buildModel(folder: folder, output: model, context: context)
            }
            try await client.upload(file: model, as: Self.macFilename(name), progress: { sent, total in
                context.update(.sending(sent: sent, total: total))
            })
            return "Sent to \(mac.name)"
        }
    }

    /// Sends the photos and lets the Mac build the model. Quicker for the phone and more detailed
    /// than building on the phone. Falls back to a clear message on a Mac that cannot do this yet.
    func sendPhotosToMac(folder: URL, name: String) {
        guard let mac = pairedMac else { showNearbyMac = true; return }
        let record = objectRecord(for: folder)
        let base = Self.macFilename(name).replacingOccurrences(of: ".usdz", with: "")
        run(title: "Send to \(mac.name)", scanId: record.id, destination: mac.name,
            success: { [weak self] _ in self?.clearPendingCapture(); self?.phase = .sentToMac(name: mac.name) },
            cancelled: { [weak self] in self?.backAfterCancel() }) { [self] context in
            try await self.deliverArchive(
                of: record.id, source: folder.appendingPathComponent("Images"), baseName: base, mac: mac,
                requires: { hello in
                    guard hello.maxCaptureBytes != nil else {
                        throw OperationError(message: "\(mac.name) runs an older 3lay Mac that cannot build from photos. "
                            + "Update it, or choose Build on this phone.")
                    }
                }, context: context)
            return "Sent to \(mac.name)"
        }
    }

    /// Packs `source` (once; a retry or a relaunch reuses the archive) and sends it to the Mac, resuming
    /// where the Mac stopped when it supports that. On success the archive is deleted. On failure or
    /// cancel it stays, together with its transfer id, so the next attempt continues.
    private func deliverArchive(
        of scanId: UUID, source: URL, baseName: String, mac: PairedMac,
        requires: (LanHello) throws -> Void, context: OperationTracker.Context
    ) async throws {
        context.update(.preparing)
        let client = try await reachableClient(for: mac)
        try await client.verifyCode()
        let hello = try await client.hello()
        try requires(hello)
        let limit = hello.maxCaptureBytes ?? LanProtocol.maxCaptureBytes

        let transfer = try await preparedTransfer(for: scanId, source: source, baseName: baseName)
        let archive = catalog.archiveURL(transfer)
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0
        if size > limit { throw LanError.tooLarge(maxBytes: limit) }
        try Task.checkCancellation()

        let progress: @Sendable (Int64, Int64) -> Void = { sent, total in context.update(.sending(sent: sent, total: total)) }
        context.update(.sending(sent: 0, total: Int64(size)))
        if hello.supportsResumableUploads == true {
            let digest = try await Task.detached(priority: .userInitiated) { try Hashing.sha256(of: archive) }.value
            do {
                try await client.uploadResumable(
                    file: archive, as: transfer.filename, transferId: transfer.id, sha256: digest, progress: progress)
            } catch LanTransferError.unknown {
                // The Mac forgot the transfer (expired, or it was reinstalled): start a fresh one.
                try? catalog.update(id: scanId) { $0.transfer?.id = UUID().uuidString }
                throw OperationError(message: "The Mac lost track of this transfer. Try sending again.")
            }
        } else {
            try await client.upload(file: archive, as: transfer.filename, progress: progress)
        }
        try? catalog.update(id: scanId) { $0.transfer = nil; $0.destination = mac.name }
        try? FileManager.default.removeItem(at: archive)
    }

    /// The archive and transfer id for this scan, created on first use. Kept in the catalog so a later
    /// attempt (even after a relaunch) reuses the same file and id.
    private func preparedTransfer(for scanId: UUID, source: URL, baseName: String) async throws -> ScanRecord.Transfer {
        if let existing = catalog.record(id: scanId)?.transfer,
           FileManager.default.fileExists(atPath: catalog.archiveURL(existing).path) { return existing }
        let temporary = try await Self.pack(imagesDirectory: source, name: baseName)
        try Task.checkCancellation()
        let outbox = catalog.root.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let stored = outbox.appendingPathComponent("\(id).zip")
        try FileManager.default.moveItem(at: temporary, to: stored)
        let transfer = ScanRecord.Transfer(id: id, archive: catalog.relativePath(of: stored), filename: temporary.lastPathComponent)
        try catalog.update(id: scanId) { $0.transfer = transfer }
        return transfer
    }

    /// Runs the on-device reconstruction, reporting real progress. Cancelling stops it and removes the partial model.
    nonisolated private static func buildModel(folder: URL, output: URL, context: OperationTracker.Context) async throws {
        do {
            try await OnDeviceReconstruction.run(
                imagesDirectory: folder.appendingPathComponent("Images"), output: output,
                progress: { context.update(.reconstructing(fraction: $0)) })
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
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
    func sendLidarToMac(name: String) {
        guard let mac = pairedMac, let pending = pendingLidar else { showNearbyMac = true; return }
        try? catalog.update(id: pending.id) { $0.status = .sending; $0.destination = mac.name }
        let base = Self.macFilename(name).replacingOccurrences(of: ".usdz", with: "") + ".lidar"
        run(title: "Send to \(mac.name)", scanId: pending.id, destination: mac.name,
            success: { [weak self] _ in
                guard let self else { return }
                try? self.catalog.discard(id: pending.id)  // delivered: LiDAR sources are not kept
                self.pendingLidar = Self.latestLidar(in: self.catalog)
                self.phase = .sentToMac(name: mac.name)
            },
            cancelled: { [weak self] in
                // Cancelled by the user: not a failure, the scan is simply waiting to be sent.
                try? self?.catalog.update(id: pending.id) { $0.status = .saved }
                self?.backAfterCancel()
            },
            failure: { [weak self] message in self?.markLidarFailed(pending.id, message) }) { [self] context in
            try await self.deliverArchive(
                of: pending.id, source: pending.folder, baseName: base, mac: mac,
                requires: { hello in
                    guard hello.supportsLidarBundles == true else {
                        throw OperationError(message: "\(mac.name) runs an older 3lay Mac that cannot import LiDAR scans. Update it first.")
                    }
                }, context: context)
            return "Sent to \(mac.name)"
        }
    }

    private func markLidarFailed(_ id: UUID, _ message: String) {
        try? catalog.update(id: id) { $0.status = .failed; $0.lastError = message }
    }

    // MARK: Packing

    /// Zipping hundreds of photos is slow, synchronous file work. Run on the main actor it froze the UI.
    nonisolated private static func pack(imagesDirectory: URL, name: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try Diagnostics.measure("archive.make") { try CaptureArchive.make(imagesDirectory: imagesDirectory, name: name) }
        }.value
    }

    nonisolated static func macFilename(_ name: String, now: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }.trimmingCharacters(in: .whitespaces)
        return "\(safe.isEmpty ? "Scan" : safe) \(stamp).usdz"
    }

    /// The catalog record for an Object Capture folder, created on first use (also for scans saved
    /// before the catalog existed).
    func objectRecord(for folder: URL) -> ScanRecord {
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

    func submit(imagesDirectory: URL, name: String) {
        guard let pairing else { phase = .needsPairing; return }
        let api = APIClient(transport: URLSessionTransport(baseURL: pairing.server, token: pairing.token))
        let submission = Submission(api: api, uploader: ResumableUploader(api: api, store: FileUploadStore()))
        let device = Self.device  // UIDevice is main-actor only; read it before the work leaves the main actor
        // The scan's folder is the Images folder's parent; its record remembers the job across retries.
        let record = objectRecord(for: imagesDirectory.deletingLastPathComponent())
        run(title: "Upload photos", scanId: record.id, destination: pairing.server.host,
            success: { [weak self] message in
                guard let self else { return }
                self.clearPendingCapture()
                self.phase = .submitted(jobId: self.submittedJob?.jobId ?? message, photos: self.submittedJob?.photos ?? 0)
            },
            cancelled: { [weak self] in self?.backAfterCancel() }) { [self] context in
            let result = try await submission.submit(
                name: name, imagesDirectory: imagesDirectory, device: device,
                jobId: record.serverJobId,
                onJobCreated: { id in
                    await MainActor.run { try? self.catalog.update(id: record.id) { $0.serverJobId = id; $0.destination = pairing.server.host } }
                },
                onProgress: { done, total in context.update(.uploading(done: done, total: total)) })
            await MainActor.run { self.submittedJob = (result.jobId, result.photoCount) }
            return result.jobId
        }
    }

    /// Reconstructs on the phone and uploads the mesh. No Mac needed, but lower detail.
    func submitOnDevice(folder: URL, name: String) {
        guard let pairing else { phase = .needsPairing; return }
        let model = folder.appendingPathComponent("model.usdz")
        let record = objectRecord(for: folder)
        run(title: "Build and upload", scanId: record.id, destination: pairing.server.host,
            success: { [weak self] jobId in
                self?.clearPendingCapture()
                self?.phase = .submitted(jobId: jobId, photos: 0)
            },
            cancelled: { [weak self] in self?.backAfterCancel() }) { context in
            context.update(.reconstructing(fraction: nil))
            try await Self.buildModel(folder: folder, output: model, context: context)
            let api = APIClient(transport: URLSessionTransport(baseURL: pairing.server, token: pairing.token))
            let uploader = ResumableUploader(api: api, store: FileUploadStore())
            let job = try await api.createJob(name: name, sourceKind: "mesh")
            context.update(.uploading(done: 0, total: 1))
            _ = try await uploader.upload(file: model, jobId: job.id, kind: "original")
            return job.id
        }
    }
}
#endif
