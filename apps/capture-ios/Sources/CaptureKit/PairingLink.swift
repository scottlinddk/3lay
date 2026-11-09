import Foundation

/// `scan3d://pair?server=https://host&token=...`, shown by the web app as a link or QR code.
public struct PairingLink: Equatable {
    public let server: URL
    public let token: String

    public init(server: URL, token: String) {
        self.server = server
        self.token = token
    }

    public init?(url: URL) {
        guard url.scheme == "scan3d", url.host == "pair",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let serverString = items.first(where: { $0.name == "server" })?.value,
            let server = URL(string: serverString), PairingLink.isAllowed(server),
            let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        self.server = server
        self.token = token
    }

    /// Tokens only travel over TLS. Plain http is for a local dev server.
    static func isAllowed(_ url: URL) -> Bool {
        if url.scheme == "https" { return true }
        return url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")
    }
}
