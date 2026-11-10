import Foundation
import Darwin
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
        let inbox = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "threelaymacos-check-\(UUID().uuidString)")
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

        // A peer can reset the connection before either response write. The receiver
        // must survive even with the default SIGPIPE disposition.
        signal(SIGPIPE, SIG_DFL)
        for _ in 0..<64 { try disconnectBeforeResponse(port: receiver.port) }
        _ = try await client.hello()

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

        // A zip of photos is a capture archive and is taken like any other upload.
        let photos = obj.deletingPathExtension().appendingPathExtension("zip")
        try Data([1, 2, 3]).write(to: photos)
        try await client.upload(file: photos)
        guard received.wait(timeout: .now() + 5) == .success, box.url?.pathExtension == "zip" else { fail("zip not accepted") }
        guard try await client.hello().maxCaptureBytes == LanProtocol.maxCaptureBytes else { fail("hello hides capture support") }
        guard try await client.hello().supportsLidarBundles == true else { fail("hello hides LiDAR bundle support") }
        // A clean rebuild is only offered once the Mac says it can, and the note arrives beside the file.
        guard try await client.hello().supportsRebuild == false else { fail("hello offers a rebuild without a key") }
        receiver.rebuildAvailable = true
        guard try await client.hello().supportsRebuild == true else { fail("hello hides rebuild support") }
        try await client.upload(file: obj, as: "noted.rebuild.obj", note: "bracket & 2 holes")
        guard received.wait(timeout: .now() + 5) == .success else { fail("noted upload not reported") }
        let noted = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix("noted.rebuild.obj.note") }
        guard noted.count == 1, try String(contentsOf: noted[0], encoding: .utf8) == "bracket & 2 holes" else { fail("the note did not arrive") }

        let junk = obj.deletingPathExtension().appendingPathExtension("exe")
        try Data([1]).write(to: junk)
        await expect(.unsupportedType, { try await client.upload(file: junk) }, "unsupported type")

        // Concurrent phones/browser sends may choose the same filename. Each completed
        // upload must retain its own path and bytes, with no partial files published.
        let batchInbox = inbox.appending(path: "batch")
        let batchReceived = DispatchSemaphore(value: 0)
        let batch = Box()
        let batchReceiver = try PhoneReceiver(code: "123456", port: 0, inbox: batchInbox, name: "Batch") { url in
            batch.url = url
            batchReceived.signal()
        }
        let batchClient = LanClient(endpoint: LanEndpoint(name: "Batch", host: "127.0.0.1", port: batchReceiver.port), code: "123456")
        let files = try (0..<16).map { i -> URL in
            let file = inbox.appending(path: "source-\(i).obj")
            try Data(repeating: UInt8(i), count: 65_536).write(to: file)
            return file
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in files { group.addTask { try await batchClient.upload(file: file, as: "same.obj") } }
            try await group.waitForAll()
        }
        for _ in files {
            guard batchReceived.wait(timeout: .now() + 5) == .success else { fail("missing concurrent upload") }
        }
        let paths = batch.urls
        guard Set(paths).count == files.count else { fail("uploads shared a destination") }
        let expected = try Set(files.map { try Data(contentsOf: $0) })
        let actual = try Set(paths.map { try Data(contentsOf: $0) })
        guard actual == expected else { fail("concurrent upload bytes were overwritten") }
        guard try FileManager.default.contentsOfDirectory(atPath: batchInbox.path).count == files.count
        else { fail("partial upload files were left behind") }

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

    static func disconnectBeforeResponse(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("could not create disconnect client") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { fail("disconnect client could not connect") }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let request = Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, $0.count, 0) }
        guard sent == request.count else { fail("disconnect request was not sent") }
        // Abort rather than gracefully draining the response.
        var reset = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size))
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL] = []
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values }
        var url: URL? {
            get { urls.last }
            set { if let newValue { lock.lock(); values.append(newValue); lock.unlock() } }
        }
    }
}
