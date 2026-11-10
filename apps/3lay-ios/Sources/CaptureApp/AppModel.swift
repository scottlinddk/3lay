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
    /// A finished LiDAR scan that has not reached the Mac yet. Kept in memory only, so after an app
    /// restart it is no longer offered (unlike Object Capture scans, which are recovered).
    @Published private(set) var pendingLidar: PendingLidar?

    struct PendingLidar: Equatable {
        let folder: URL
        let photos: Int
        let triangles: Int
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
        phase = folder.map { Phase.choosing(folder: $0) }
            ?? ((link == nil && mac == nil) ? .needsPairing : .ready)
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
                    progress: { fraction in Task { @MainActor in self.phase = .reconstructing(fraction) } })
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
                    progress: { fraction in Task { @MainActor in self.phase = .reconstructing(fraction) } })
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
            let zip = try CaptureArchive.make(
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
        phase = .lidarCapturing
    }

    func lidarCaptureFinished(folder: URL, photos: Int, triangles: Int) {
        pendingLidar = PendingLidar(folder: folder, photos: photos, triangles: triangles)
        phase = .lidarReady
    }

    func discardLidar() {
        if let folder = pendingLidar?.folder { try? FileManager.default.removeItem(at: folder) }
        pendingLidar = nil
        phase = isPaired ? .ready : .needsPairing
    }

    /// Zips the LiDAR bundle as `<name>.lidar.zip` and sends it. 3lay Mac imports the mesh as is.
    func sendLidarToMac(name: String) async {
        guard let mac = pairedMac, let pending = pendingLidar else { showNearbyMac = true; return }
        var archive: URL?
        defer { archive.map { try? FileManager.default.removeItem(at: $0) } }
        do {
            phase = .sendingToMac(name: mac.name)
            let client = try await reachableClient(for: mac)
            try await client.verifyCode()
            let hello = try await client.hello()
            guard hello.supportsLidarBundles == true, let limit = hello.maxCaptureBytes else {
                phase = .failed("\(mac.name) runs an older 3lay Mac that cannot import LiDAR scans. "
                    + "Update it first. Your scan is kept on this phone.")
                return
            }
            let zip = try CaptureArchive.make(
                imagesDirectory: pending.folder,
                name: Self.macFilename(name).replacingOccurrences(of: ".usdz", with: "") + ".lidar")
            archive = zip
            let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
            if size > limit { throw LanError.tooLarge(maxBytes: limit) }
            try await client.upload(file: zip)
            try? FileManager.default.removeItem(at: pending.folder)
            pendingLidar = nil
            phase = .sentToMac(name: mac.name)
        } catch LanError.wrongCode, LanError.lockedOut {
            phase = .failed("\(mac.name) did not accept the code. If you made a new code on the Mac, "
                + "open Nearby Mac and enter it again. Your scan is kept on this phone.")
        } catch {
            phase = .failed("Could not send to \(mac.name): \(error.localizedDescription) Your scan is kept on this phone.")
        }
    }

    static func macFilename(_ name: String, now: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }.trimmingCharacters(in: .whitespaces)
        return "\(safe.isEmpty ? "Scan" : safe) \(stamp).usdz"
    }

    func captureFinished(folder: URL) {
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
        else if pendingLidar != nil { phase = .lidarReady }
        else { phase = isPaired ? .ready : .needsPairing }
    }

    /// Leaves the "Capture complete" screen but keeps the scan, so "Resume saved capture" can reopen it.
    func leaveCapture() {
        phase = isPaired ? .ready : .needsPairing
    }

    /// Deletes the unsent scan for good. Callers must have asked the user first.
    func discardCapture() {
        if let folder = pendingCapture { try? FileManager.default.removeItem(at: folder) }
        clearPendingCapture()
        phase = isPaired ? .ready : .needsPairing
    }

    private func clearPendingCapture() {
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
        do {
            let result = try await submission.submit(
                name: name, imagesDirectory: imagesDirectory, device: Self.device,
                onProgress: { done, total in
                    Task { @MainActor in self.phase = .submitting(done: done, total: total) }
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
                progress: { fraction in Task { @MainActor in self.phase = .reconstructing(fraction) } })
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
