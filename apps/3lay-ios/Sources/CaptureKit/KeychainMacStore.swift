import Foundation
import Security

/// A Mac running 3lay Mac that this phone has paired with over the local network. The code is
/// that Mac's pairing code. It is not the server device token and lives under its own Keychain item.
public struct PairedMac: Codable, Equatable {
    public var name: String   // Bonjour name, used to find the Mac again if its IP address changes
    public var host: String   // last known address
    public var port: UInt16
    public var code: String

    public init(name: String, host: String, port: UInt16, code: String) {
        self.name = name
        self.host = host
        self.port = port
        self.code = code
    }
}

public struct KeychainMacStore {
    public let service: String

    public init(service: String = "app.scan3d.capture.lan") { self.service = service }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    public func save(_ mac: PairedMac) throws {
        let blob = try JSONEncoder().encode(mac)
        SecItemDelete(baseQuery as CFDictionary)
        let status = SecItemAdd(
            baseQuery.merging([
                kSecValueData as String: blob,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func load() -> PairedMac? {
        let query = baseQuery.merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    public func clear() { SecItemDelete(baseQuery as CFDictionary) }
}
