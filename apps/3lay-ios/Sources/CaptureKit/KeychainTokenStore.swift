import Foundation
import Security

/// Stores the pairing (server URL and device token) in the Keychain, never in UserDefaults.
public struct KeychainPairingStore {
    public let service: String

    public init(service: String = "app.scan3d.capture") { self.service = service }

    public func save(_ link: PairingLink) throws {
        let blob = try JSONEncoder().encode(["server": link.server.absoluteString, "token": link.token])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(
            query.merging([
                kSecValueData as String: blob,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func load() -> PairingLink? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let dict = try? JSONDecoder().decode([String: String].self, from: data),
            let server = dict["server"].flatMap(URL.init(string:)), let token = dict["token"]
        else { return nil }
        return PairingLink(server: server, token: token)
    }

    public func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
