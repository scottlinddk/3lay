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

    private func perform(
        _ request: URLRequest, file: URL? = nil, body: Data? = nil,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> (Data, Int) {
        do {
            let (data, response): (Data, URLResponse)
            if let file {
                #if canImport(FoundationNetworking)
                (data, response) = try await session.upload(for: request, fromFile: file)
                #else
                let delegate = progress.map { ProgressDelegate($0) }
                (data, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
                #endif
            } else if let body {
                (data, response) = try await session.upload(for: request, from: body)
            } else {
                (data, response) = try await session.data(for: request)
            }
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // Cancelling the surrounding task cancels the request; that is not a network failure.
            throw CancellationError()
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
    /// `progress` receives (bytes sent, bytes total) as the body goes out. Cancelling the calling task
    /// stops the transfer and throws `CancellationError`.
    public func upload(
        file: URL, as filename: String? = nil, progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        let name = filename ?? file.lastPathComponent
        guard LanProtocol.isAcceptedUpload(name) else { throw LanError.unsupportedType }
        let limit = LanProtocol.maxBytes(for: name)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= limit else { throw LanError.tooLarge(maxBytes: limit) }
        var request = authorized(try url(LanProtocol.uploadPath(for: name)), method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await perform(request, file: file, progress: progress)
        try check(status: status, body: data, maxBytes: limit)
    }
}

#if !canImport(FoundationNetworking)
/// Reports how many bytes of the request body URLSession has handed to the network.
final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let report: @Sendable (Int64, Int64) -> Void
    init(_ report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) { report(totalBytesSent, totalBytesExpectedToSend) }
}
#endif

// MARK: Resumable uploads

extension LanClient {
    /// Sends `file` in acknowledged chunks. Safe to call again after any failure, including an app
    /// relaunch, with the same `transferId` and an unchanged file: it asks the Mac where it stopped and
    /// continues from there. `progress` reports bytes the Mac has acknowledged, not bytes queued.
    public func uploadResumable(
        file: URL, as filename: String? = nil, transferId: String, sha256: String,
        chunkBytes: Int = LanProtocol.transferChunkBytes, maxRetries: Int = 4,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        let name = filename ?? file.lastPathComponent
        guard LanProtocol.isAcceptedUpload(name) else { throw LanError.unsupportedType }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let limit = LanProtocol.maxBytes(for: name)
        guard size <= limit else { throw LanError.tooLarge(maxBytes: limit) }

        var state = try await begin(id: transferId, name: name, size: size, sha256: sha256)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var failures = 0
        while !state.complete {
            try Task.checkCancellation()
            progress?(Int64(state.offset), Int64(size))
            try handle.seek(toOffset: UInt64(state.offset))
            let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
            if chunk.isEmpty && state.offset < size {
                throw LanError.rejected(status: 0, message: "The file changed while it was being sent.")
            }
            do {
                state = try await patch(id: transferId, offset: state.offset, chunk: chunk)
                failures = 0
            } catch let error as CancellationError {
                throw error
            } catch LanTransferError.offsetMismatch(let current) {
                // A lost response: the Mac already has more (or less) than we thought. Trust the Mac.
                state.offset = current
                state.complete = current >= size
                failures += 1
                if failures > maxRetries { throw LanTransferError.offsetMismatch(current: current) }
            } catch LanError.unreachable(let why) {
                failures += 1
                if failures > maxRetries { throw LanError.unreachable(why) }
                try await Task.sleep(nanoseconds: UInt64(min(failures, 4)) * 500_000_000)
                state = try await status(id: transferId)  // where did the Mac get to?
            }
        }
        progress?(Int64(size), Int64(size))
    }

    private func begin(id: String, name: String, size: Int, sha256: String) async throws -> LanTransferInfo {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        let query = "?name=\(name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)&size=\(size)&sha256=\(sha256)"
        var request = authorized(try url(LanProtocol.transferPath(id: id) + query), method: "POST")
        let (data, status) = try await perform(request)
        return try decodeTransfer(status: status, data: data)
    }

    private func status(id: String) async throws -> LanTransferInfo {
        let (data, status) = try await perform(authorized(try url(LanProtocol.transferPath(id: id)), method: "GET"))
        return try decodeTransfer(status: status, data: data)
    }

    private func patch(id: String, offset: Int, chunk: Data) async throws -> LanTransferInfo {
        var request = authorized(try url(LanProtocol.transferPath(id: id)), method: "PATCH")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await perform(request, body: chunk)
        return try decodeTransfer(status: status, data: data)
    }

    private func decodeTransfer(status: Int, data: Data) throws -> LanTransferInfo {
        switch status {
        case 200..<300:
            guard let info = try? JSONDecoder().decode(LanTransferInfo.self, from: data) else {
                throw LanError.rejected(status: status, message: "unreadable transfer state")
            }
            return info
        case 404: throw LanTransferError.unknown
        case 409:
            // Body is the receiver's current state. Complete or not, the offset is what to continue from.
            if let info = try? JSONDecoder().decode(LanTransferInfo.self, from: data) {
                if info.complete { return info }
                throw LanTransferError.offsetMismatch(current: info.offset)
            }
            throw LanTransferError.conflict
        case 422: throw LanTransferError.checksumMismatch
        default: try check(status: status, body: data); throw LanError.rejected(status: status, message: "")
        }
    }
}
