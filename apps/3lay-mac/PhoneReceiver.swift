import Foundation
#if canImport(ScanLinkCore)
import ScanLinkCore  // SwiftPM builds; build.sh compiles the same sources straight into this target.
#endif
import Darwin

/// Local-network HTTP receiver. The wire contract (routes, port, limits) is in ScanLinkCore and
/// documented in docs/LAN_LINK.md. Both the iOS app and the browser upload page use it.
final class PhoneReceiver {
    private let socketFD: Int32
    private let lock = NSLock()
    private var currentCode: String
    private var failedAttempts = 0
    private var lockedUntil = Date.distantPast
    private let inbox: URL
    private let helloName: String
    private let onFile: (URL) -> Void
    /// The port actually bound. Differs from the requested one only when 0 was requested.
    let port: UInt16

    var code: String {
        get { lock.lock(); defer { lock.unlock() }; return currentCode }
        set { lock.lock(); currentCode = newValue; failedAttempts = 0; lockedUntil = .distantPast; lock.unlock() }
    }

    /// Where received scans are saved. Not the working directory: a Finder-launched app starts in `/`.
    static var defaultInbox: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ThreeLayMacOS/inbox", directoryHint: .isDirectory)
    }

    init(code: String, port requested: UInt16 = LanProtocol.defaultPort, inbox: URL = PhoneReceiver.defaultInbox,
         name: String = LanAdvertiser.displayName, onFile: @escaping (URL) -> Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ScanError.message("Could not create phone receiver") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(requested).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ScanError.message("Port \(requested) is unavailable")
        }
        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &boundLength) }
        }
        socketFD = fd
        port = UInt16(bigEndian: bound.sin_port)
        currentCode = code
        self.inbox = inbox
        helloName = name
        self.onFile = onFile
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = accept(socketFD, nil, nil)
                if client < 0 { break }
                // A phone can disconnect before we send the response. Return EPIPE instead
                // of terminating the app with SIGPIPE, including for unauthenticated requests.
                var noSigPipe: Int32 = 1
                guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                                 socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    close(client)
                    continue
                }
                DispatchQueue.global(qos: .utility).async { [self] in
                    defer { close(client) }
                    handle(client)
                }
            }
        }
    }

    deinit { close(socketFD) }

    static func localIP() -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return "localhost" }
        defer { freeifaddrs(list) }
        var current = list
        while let entry = current {
            let iface = entry.pointee
            if iface.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
               let name = String(validatingUTF8: iface.ifa_name), name == "en0" || name == "en1" {
                var address = iface.ifa_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count))
                return String(cString: buffer)
            }
            current = iface.ifa_next
        }
        return "localhost"
    }

    static let uploadPage = #"<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>Send a scan</title><style>body{background:#161e25;color:#e9eff2;font:16px system-ui;max-width:520px;margin:60px auto;padding:24px}h1{font-size:28px}label{display:block;margin:28px 0 8px}input{width:100%;padding:18px;border:2px dashed #6b8b89;border-radius:14px;box-sizing:border-box}button{background:#6bc7ad;color:#102423;border:0;border-radius:10px;padding:15px 22px;font-weight:bold;margin-top:20px}small{color:#a8b7bc}#status{margin-top:22px}</style><h1>Send a 3D scan</h1><p>Choose a surface mesh. It will appear on the desktop plate.</p><label>Pairing code shown on desktop</label><input id="code" inputmode="numeric" maxlength="6"><label>STL, OBJ, ASCII PLY or USDZ</label><input id="file" type="file" accept=".stl,.obj,.ply,.usdz"><button onclick="sendFile()">Send to desktop</button><p id="status"></p><small>Both devices must be on the same Wi-Fi network. Your file stays on this computer.</small><script>async function sendFile(){let f=document.getElementById('file').files[0],s=document.getElementById('status');if(!f){s.textContent='Choose a file first';return}let code=document.getElementById('code').value;if(!/^\d{6}$/.test(code)){s.textContent='Enter the six-digit pairing code';return}s.textContent='Sending…';try{let r=await fetch('/upload/'+encodeURIComponent(f.name)+'?code='+code,{method:'PUT',body:f});s.textContent=r.ok?'Received. Check the desktop app.':await r.text()}catch(e){s.textContent='Could not reach the desktop app'}}</script>"#

    /// nil when the request carries the right code, otherwise the error response to send.
    /// Accepts `Authorization: Bearer <code>` (iOS app) or `?code=` (browser page). Repeated
    /// wrong codes lock the receiver, because six digits are guessable on a shared network.
    private func authorize(_ components: URLComponents, _ headerLines: [String]) -> (status: String, message: String)? {
        let bearer = headerLines.lazy.compactMap { line -> String? in
            let p = line.split(separator: ":", maxSplits: 1)
            guard p.count == 2, p[0].lowercased() == "authorization" else { return nil }
            let value = p[1].trimmingCharacters(in: .whitespaces)
            return value.lowercased().hasPrefix("bearer ") ? String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil
        }.first
        let supplied = bearer ?? components.queryItems?.first(where: { $0.name == "code" })?.value ?? ""
        lock.lock(); defer { lock.unlock() }
        if Date() < lockedUntil { return ("429 Too Many Requests", "Too many wrong codes. Try again in a minute.") }
        if PhoneReceiver.constantTimeEqual(supplied, currentCode) { failedAttempts = 0; return nil }
        failedAttempts += 1
        if failedAttempts >= LanProtocol.maxFailedAttempts {
            lockedUntil = Date().addingTimeInterval(LanProtocol.lockoutSeconds)
            failedAttempts = 0
        }
        return ("403 Forbidden", "Pairing code does not match")
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)) }
        return diff == 0
    }

    private func respond(_ fd: Int32, _ status: String, _ contentType: String, _ body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, PUT, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\n\r\n"
        sendAll(fd, Data(header.utf8))
        sendAll(fd, body)
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func handle(_ fd: Int32) {
        var timeout = timeval(tv_sec: 40, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Int?
        while headerEnd == nil && bytes.count <= 16_384 {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return }
            bytes.append(contentsOf: buffer.prefix(n))
            headerEnd = bytes.range(of: Data([13, 10, 13, 10]))?.upperBound
        }
        guard let end = headerEnd, end <= 16_384 else { respond(fd, "431 Request Header Fields Too Large", "text/plain", Data("Headers too large".utf8)); return }
        guard let header = String(data: bytes.prefix(end), encoding: .utf8), let first = header.components(separatedBy: "\r\n").first else { return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0]), route = String(parts[1])
        if method == "OPTIONS" { respond(fd, "204 No Content", "text/plain", Data()); return }
        guard let components = URLComponents(string: "http://localhost\(route)") else {
            respond(fd, "400 Bad Request", "text/plain", Data("Bad request".utf8)); return
        }
        let headerLines = header.components(separatedBy: "\r\n")
        if method == "GET" {
            switch components.path {
            case "/":
                respond(fd, "200 OK", "text/html; charset=utf-8", Data(PhoneReceiver.uploadPage.utf8))
            case LanProtocol.helloPath:
                let body = (try? JSONEncoder().encode(LanHello(name: helloName))) ?? Data()
                respond(fd, "200 OK", "application/json", body)
            case LanProtocol.authPath:
                if let failure = authorize(components, headerLines) { respond(fd, failure.status, "text/plain", Data(failure.message.utf8)) }
                else { respond(fd, "200 OK", "text/plain", Data("ok".utf8)) }
            default:
                respond(fd, "404 Not Found", "text/plain", Data("Not found".utf8))
            }
            return
        }
        guard method == "PUT", components.path.hasPrefix(LanProtocol.uploadPrefix) else {
            respond(fd, "404 Not Found", "text/plain", Data("Not found".utf8)); return
        }
        if let failure = authorize(components, headerLines) {
            respond(fd, failure.status, "text/plain", Data(failure.message.utf8)); return
        }
        let name = URL(fileURLWithPath: components.path).lastPathComponent
        guard LanProtocol.isAcceptedFilename(name) else {
            respond(fd, "415 Unsupported Media Type", "text/plain", Data("Send STL, OBJ, ASCII PLY or USDZ".utf8)); return
        }
        let length = headerLines.compactMap { line -> Int? in
            let p = line.split(separator: ":", maxSplits: 1)
            return p.count == 2 && p[0].lowercased() == "content-length" ? Int(p[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first
        guard let length, length >= 0 else { respond(fd, "411 Length Required", "text/plain", Data("Content-Length required".utf8)); return }
        guard length <= LanProtocol.maxUploadBytes else { respond(fd, "413 Payload Too Large", "text/plain", Data("100 MB maximum".utf8)); return }
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let temporary = inbox.appending(path: ".\(id).upload")
            let file = inbox.appending(path: "\(id)-\(name)")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw ScanError.message("Could not create upload file")
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let stream = try FileHandle(forWritingTo: temporary)
            defer { try? stream.close() }
            var written = min(length, bytes.count - end)
            try stream.write(contentsOf: bytes[end..<(end + written)])
            while written < length {
                let n = recv(fd, &buffer, min(buffer.count, length - written), 0)
                if n <= 0 { return }
                try stream.write(contentsOf: buffer.prefix(n))
                written += n
            }
            try stream.close()
            try FileManager.default.moveItem(at: temporary, to: file)
            respond(fd, "200 OK", "text/plain", Data("Scan received".utf8))
            onFile(file)
        } catch { respond(fd, "500 Internal Server Error", "text/plain", Data("Could not save scan".utf8)) }
    }
}
