import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux, used for CI outside macOS
#endif

public enum LanError: Error, Equatable, LocalizedError {
    case notLocalNetwork
    case notThreeLayMacOS
    case wrongCode
    case lockedOut
    case unsupportedType
    case tooLarge(maxBytes: Int)
    case rejected(status: Int, message: String)
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .notLocalNetwork: return "That address is not on your local network."
        case .notThreeLayMacOS: return "That device is not running 3lay Mac."
        case .wrongCode: return "The pairing code does not match the one shown on the Mac."
        case .lockedOut: return "Too many wrong codes. Wait a minute and try again."
        case .unsupportedType: return "The Mac only accepts STL, OBJ, PLY, USDZ or a zip of photos."
        case .tooLarge(let max): return "The file is larger than the Mac's \(max / 1_000_000) MB limit."
        case .rejected(let status, let message): return "The Mac refused the request (\(status)): \(message)"
        case .unreachable(let why): return "Could not reach the Mac: \(why)"
        }
    }
}

/// Talks to a 3lay Mac receiver over plain HTTP on the local network. The pairing code is a
/// short-lived shared secret for this one receiver. It is not the server device token and is
/// never sent anywhere else.
public struct LanClient {
    public let endpoint: LanEndpoint
    public let code: String
    let session: URLSession

    public init(endpoint: LanEndpoint, code: String, session: URLSession = LanClient.makeSession()) {
        self.endpoint = endpoint
        self.code = code
        self.session = session
    }

    /// Ephemeral, no cellular: a scan must not leave the Wi-Fi network by accident.
    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.allowsCellularAccess = false
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 900
        return URLSession(configuration: c)
    }

    private func url(_ path: String) throws -> URL {
        guard endpoint.isLocalNetwork else { throw LanError.notLocalNetwork }
        guard let base = endpoint.baseURL, let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw LanError.unreachable("invalid address")
        }
        return url
    }

    private func perform(_ request: URLRequest, file: URL? = nil) async throws -> (Data, Int) {
        do {
            let (data, response): (Data, URLResponse)
            if let file { (data, response) = try await session.upload(for: request, fromFile: file) } else {
                (data, response) = try await session.data(for: request)
            }
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch { throw LanError.unreachable(error.localizedDescription) }
    }

    private func authorized(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func check(status: Int, body: Data, maxBytes: Int = LanProtocol.maxUploadBytes) throws {
        switch status {
        case 200..<300: return
        case 403: throw LanError.wrongCode
        case 429: throw LanError.lockedOut
        case 413: throw LanError.tooLarge(maxBytes: maxBytes)
        case 415: throw LanError.unsupportedType
        default: throw LanError.rejected(status: status, message: String(decoding: body.prefix(200), as: UTF8.self))
        }
    }

    /// Public handshake. Proves the address is a 3lay Mac receiver before any code is sent.
    public func hello() async throws -> LanHello {
        var request = URLRequest(url: try url(LanProtocol.helloPath))
        request.timeoutInterval = 5
        let (data, status) = try await perform(request)
        guard status == 200, let hello = try? JSONDecoder().decode(LanHello.self, from: data),
            hello.service == LanProtocol.serviceName
        else { throw LanError.notThreeLayMacOS }
        return hello
    }

    /// Checks the code without uploading anything.
    public func verifyCode() async throws {
        var request = authorized(try url(LanProtocol.authPath), method: "GET")
        request.timeoutInterval = 5
        let (data, status) = try await perform(request)
        try check(status: status, body: data)
    }

    /// Streams `file` to the Mac. `filename` is what the Mac saves it as (default: the file's name).
    public func upload(file: URL, as filename: String? = nil) async throws {
        let name = filename ?? file.lastPathComponent
        guard LanProtocol.isAcceptedUpload(name) else { throw LanError.unsupportedType }
        let limit = LanProtocol.maxBytes(for: name)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= limit else { throw LanError.tooLarge(maxBytes: limit) }
        var request = authorized(try url(LanProtocol.uploadPath(for: name)), method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await perform(request, file: file)
        try check(status: status, body: data, maxBytes: limit)
    }
}
