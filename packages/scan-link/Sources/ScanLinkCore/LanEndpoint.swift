import Foundation

/// Where a 3lay Mac receiver can be reached on the local network.
public struct LanEndpoint: Codable, Equatable {
    public var name: String
    public var host: String
    public var port: UInt16

    public init(name: String, host: String, port: UInt16) {
        self.name = name
        self.host = host
        self.port = port
    }

    public var baseURL: URL? {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(h):\(port)")
    }

    /// Accepts `192.168.1.5`, `192.168.1.5:8765`, `my-mac.local:9000` or `http://my-mac.local`.
    /// Refuses anything that is not a local-network address: the pairing code and the scan travel
    /// over plain HTTP, so they must never be sent to the internet.
    public static func parse(_ text: String, name: String? = nil) -> LanEndpoint? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("http://") { s.removeFirst("http://".count) }
        if s.hasSuffix("/") { s.removeLast() }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || parts.count == 2, let host = parts.first, !host.isEmpty,
            host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        var port = LanProtocol.defaultPort
        if parts.count == 2 {
            guard let p = UInt16(parts[1]), p > 0 else { return nil }
            port = p
        }
        let endpoint = LanEndpoint(name: name ?? host, host: host, port: port)
        return endpoint.isLocalNetwork ? endpoint : nil
    }

    /// Private, link-local, loopback, CGNAT/overlay (Tailscale) IPv4, `.local` names and
    /// single-label names. Everything else is treated as the public internet.
    public var isLocalNetwork: Bool {
        let h = host.lowercased()
        let octets = h.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        if octets.count == 4, octets.allSatisfy({ $0 != nil }) {
            let o = octets.map { $0! }
            switch (o[0], o[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if h.contains(":") { return h.hasPrefix("fe80:") || h.hasPrefix("fd") || h == "::1" }
        return h.hasSuffix(".local") || !h.contains(".")
    }
}
