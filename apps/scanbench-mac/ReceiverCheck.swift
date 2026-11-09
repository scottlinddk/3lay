import Foundation
#if canImport(ScanLinkCore)
import ScanLinkCore
#endif

/// Loopback check of the LAN contract: the real iOS-side `LanClient` talks to the real
/// `PhoneReceiver` on an ephemeral port. Run by `./rebuild_check`. It does not cover Bonjour,
/// Wi-Fi or the phone itself.
@main struct ReceiverCheck {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ReceiverCheck failed: \(message)\n".utf8))
        exit(1)
    }

    static func expect(_ error: LanError, _ body: () async throws -> Void, _ label: String) async {
        do { try await body(); fail("\(label): expected \(error)") } catch let thrown as LanError {
            if thrown != error { fail("\(label): expected \(error), got \(thrown)") }
        } catch { fail("\(label): unexpected \(error)") }
    }

    static func main() async throws {
        let inbox = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "scanbench-check-\(UUID().uuidString)")
        let received = DispatchSemaphore(value: 0)
        let box = Box()
        let receiver = try PhoneReceiver(code: "123456", port: 0, inbox: inbox, name: "Check Mac") { url in
            box.url = url
            received.signal()
        }
        guard receiver.port != 0 else { fail("no port bound") }
        let endpoint = LanEndpoint(name: "Check Mac", host: "127.0.0.1", port: receiver.port)
        let client = LanClient(endpoint: endpoint, code: "123456")

        let hello = try await client.hello()
        guard hello.name == "Check Mac", hello.version == LanProtocol.version else { fail("hello mismatch") }
        try await client.verifyCode()

        let obj = inbox.deletingLastPathComponent().appending(path: "my triangle \(UUID().uuidString).obj")
        try "v 0 0 0\nv 20 0 0\nv 0 10 0\nf 1 2 3\n".write(to: obj, atomically: true, encoding: .utf8)
        try await client.upload(file: obj)
        guard received.wait(timeout: .now() + 5) == .success, let saved = box.url else { fail("receiver did not report the file") }
        guard saved.deletingLastPathComponent().path == inbox.path else { fail("saved outside the inbox: \(saved.path)") }
        guard saved.lastPathComponent.hasSuffix(obj.lastPathComponent) else { fail("name not preserved: \(saved.lastPathComponent)") }
        guard try Mesh.load(saved).faces.count == 1 else { fail("received mesh did not load") }

        let usdz = obj.deletingPathExtension().appendingPathExtension("usdz")
        try Data([1, 2, 3]).write(to: usdz)
        try await client.upload(file: usdz)
        guard received.wait(timeout: .now() + 5) == .success else { fail("usdz not accepted") }

        // A multi-chunk body must arrive byte for byte.
        let big = obj.deletingPathExtension().appendingPathExtension("ply")
        let payload = Data((0..<(24 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: big)
        try await client.upload(file: big)
        guard received.wait(timeout: .now() + 10) == .success, let bigSaved = box.url,
              try Data(contentsOf: bigSaved) == payload else { fail("large upload corrupted") }

        let junk = obj.deletingPathExtension().appendingPathExtension("zip")
        try Data([1]).write(to: junk)
        await expect(.unsupportedType, { try await client.upload(file: junk) }, "unsupported type")

        // Rotating the code must invalidate the old one.
        receiver.code = "654321"
        await expect(.wrongCode, { try await client.verifyCode() }, "stale code")
        try await LanClient(endpoint: endpoint, code: "654321").verifyCode()

        // The Nth wrong code is still refused as wrong and starts the lockout. After that even the
        // right code is refused until the lockout ends.
        let wrong = LanClient(endpoint: endpoint, code: "000000")
        for _ in 1...LanProtocol.maxFailedAttempts { await expect(.wrongCode, { try await wrong.verifyCode() }, "wrong code") }
        await expect(.lockedOut, { try await wrong.verifyCode() }, "lockout")
        await expect(.lockedOut, { try await LanClient(endpoint: endpoint, code: "654321").verifyCode() }, "locked for right code")

        try? FileManager.default.removeItem(at: inbox)
        print("LAN receiver check passed")
    }

    final class Box: @unchecked Sendable { var url: URL? }
}
