#if os(iOS)
import ARKit
import CaptureKit
import Foundation
import RoomPlan

/// Runs Apple's RoomPlan on the same ARSession as the LiDAR capture and saves its layout as the bundle's
/// `room/` sidecar: walls, doors, windows and furniture boxes with real dimensions, in the same ARKit world as
/// the photos. RoomPlan models rooms and large furniture. It does not model small objects, so it is only
/// started for room scans (Object Capture stays the path for small objects).
///
/// RoomPlan takes over the ARSession's configuration, so `LidarCapture` re-adds mesh and depth to it.
@MainActor
final class RoomPlanRecorder: NSObject, RoomCaptureSessionDelegate {
    static var isSupported: Bool { RoomCaptureSession.isSupported }

    private let session: RoomCaptureSession
    private var continuation: CheckedContinuation<CapturedRoomData?, Never>?

    init(arSession: ARSession) {
        session = RoomCaptureSession(arSession: arSession)
        super.init()
        session.delegate = self
    }

    func start() { session.run(configuration: RoomCaptureSession.Configuration()) }

    /// Stops RoomPlan without saving anything (a cancelled scan). The ARSession keeps running.
    func cancel() {
        resume(with: nil)
        session.stop(pauseARSession: false)
    }

    /// Stops RoomPlan, builds the final layout and writes `room/room.json`, `room/room-data.json` and a USDZ
    /// into `folder`. nil if RoomPlan produced nothing usable; the scan is still good without the layout.
    func finish(into folder: URL) async -> LidarManifest.Room? {
        guard !Task.isCancelled else { return nil }
        let data: CapturedRoomData? = await withCheckedContinuation { next in
            continuation = next
            session.stop(pauseARSession: false)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                self?.resume(with: nil)  // RoomPlan never reported back
            }
        }
        guard let data, !Task.isCancelled else { return nil }
        let directory = folder.appendingPathComponent("room")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The raw capture first: RoomBuilder can be re-run on it later even if building fails now.
            var dataFile: String?
            if let raw = try? JSONEncoder().encode(data),
               (try? raw.write(to: directory.appendingPathComponent("room-data.json"), options: .atomic)) != nil {
                dataFile = "room/room-data.json"
            }
            let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
            try Task.checkCancellation()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(room).write(to: directory.appendingPathComponent("room.json"), options: .atomic)
            var usdz: String?
            if (try? room.export(to: directory.appendingPathComponent("room.usdz"), exportOptions: .parametric)) != nil {
                usdz = "room/room.usdz"
            }
            return LidarManifest.Room(
                file: "room/room.json", data: dataFile, usdz: usdz, walls: room.walls.count, doors: room.doors.count,
                windows: room.windows.count, openings: room.openings.count, objects: room.objects.count)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private func resume(with data: CapturedRoomData?) {
        continuation?.resume(returning: data)
        continuation = nil
    }

    nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        // With an error RoomPlan still hands over what it has, which is worth keeping.
        Task { @MainActor in self.resume(with: data) }
    }
}
#endif
