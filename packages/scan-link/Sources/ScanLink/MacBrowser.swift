#if canImport(Network)
import Foundation
import Network

/// A Scanbench receiver seen on the network through Bonjour. Not yet resolved to an address.
public struct DiscoveredMac: Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    let endpoint: NWEndpoint
}

/// Runs a closure at most once, from any thread.
private final class Once {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// Browses for `_scanbench._tcp` services. Callbacks arrive on the main queue.
///
/// iOS shows the Local Network permission prompt the first time this starts. If the user
/// declined, the browser stays in `.waiting` and `onProblem` explains how to fix it.
public final class MacBrowser {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "scan-link.browser")
    public var onResults: (([DiscoveredMac]) -> Void)?
    public var onProblem: ((String?) -> Void)?

    public init() {
        browser = NWBrowser(for: .bonjour(type: LanProtocol.serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            let problem: String?
            switch state {
            case .waiting, .failed:
                problem = "Cannot search the network. Allow Local Network access for this app in "
                    + "Settings > Privacy & Security > Local Network, and make sure Wi-Fi is on."
            default: problem = nil
            }
            DispatchQueue.main.async { self?.onProblem?(problem) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> DiscoveredMac? in
                if case let .service(name, _, _, _) = result.endpoint {
                    return DiscoveredMac(name: name, endpoint: result.endpoint)
                }
                return nil
            }.sorted { $0.name < $1.name }
            DispatchQueue.main.async { self?.onResults?(macs) }
        }
    }

    public func start() { browser.start(queue: queue) }
    public func stop() { browser.cancel() }

    /// Finds one Mac by its Bonjour name, for reconnecting after its IP address changed.
    public static func find(name: String, timeout: TimeInterval = 5) async -> DiscoveredMac? {
        let browser = MacBrowser()
        return await withCheckedContinuation { continuation in
            let once = Once()
            browser.onResults = { macs in
                if let hit = macs.first(where: { $0.name == name }) {
                    once.run { browser.stop(); browser.onResults = nil; continuation.resume(returning: hit) }
                }
            }
            browser.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.run { browser.stop(); browser.onResults = nil; continuation.resume(returning: nil) }
            }
        }
    }

    /// Turns a Bonjour service into an IPv4 address and port by opening (and closing) one TCP
    /// connection. IPv4 only: link-local IPv6 needs an interface scope that URLs cannot carry.
    public static func resolve(_ mac: DiscoveredMac, timeout: TimeInterval = 5) async throws -> LanEndpoint {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: mac.endpoint, using: parameters)
        let queue = DispatchQueue(label: "scan-link.resolve")
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        let endpoint = LanEndpoint(name: mac.name, host: hostString(host), port: port.rawValue)
                        once.run { continuation.resume(returning: endpoint) }
                    } else {
                        once.run { continuation.resume(throwing: LanError.unreachable("no address")) }
                    }
                    connection.cancel()
                case .failed(let error):
                    once.run { continuation.resume(throwing: LanError.unreachable("\(error)")) }
                    connection.cancel()
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.run { continuation.resume(throwing: LanError.unreachable("timed out")) }
                connection.cancel()
            }
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        let text: String
        switch host {
        case .ipv4(let address): text = address.debugDescription
        case .ipv6(let address): text = address.debugDescription
        case .name(let name, _): text = name
        @unknown default: text = "\(host)"
        }
        // Drop an interface scope such as "%en0".
        return text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
    }
}
#endif
