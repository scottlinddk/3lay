import Foundation
#if canImport(ScanLinkCore)
import ScanLinkCore  // SwiftPM builds; build.sh compiles the same sources straight into this target.
#endif

/// Publishes the receiver on Bonjour as `_threelaymacos._tcp` so the iOS app can find this Mac
/// without typing an address. Must be created and started on the main thread (NetService
/// needs a run loop).
final class LanAdvertiser: NSObject, NetServiceDelegate {
    private let service: NetService
    private(set) var publishedName: String
    var onStatus: ((String) -> Void)?

    static var displayName: String { Host.current().localizedName ?? "Mac" }

    init(name: String = LanAdvertiser.displayName, port: UInt16) {
        publishedName = name
        service = NetService(domain: "", type: "\(LanProtocol.serviceType).", name: name, port: Int32(port))
        super.init()
        service.delegate = self
        let txt: [String: Data] = ["v": Data(String(LanProtocol.version).utf8)]
        _ = service.setTXTRecord(NetService.data(fromTXTRecord: txt))
    }

    func start() { service.publish() }
    func stop() { service.stop() }

    func netServiceDidPublish(_ sender: NetService) {
        // Bonjour renames on conflict ("Studio (2)"), so report the name that was really used.
        publishedName = sender.name
        onStatus?("Visible to phones as “\(sender.name)”")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        onStatus?("Not visible to phones (Bonjour error). Type the address on the phone instead.")
    }
}
