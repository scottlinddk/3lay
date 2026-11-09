// swift-tools-version:5.9
import PackageDescription

// The LAN contract between the iOS capture app and the Mac ThreeLayMacOS app.
// ScanLinkCore is Foundation-only so ThreeLayMacOS can compile it with plain swiftc (see
// apps/3lay-mac/build.sh). ScanLink adds Bonjour discovery for iOS.
let package = Package(
    name: "scan-link",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "ScanLinkCore", targets: ["ScanLinkCore"]),
        .library(name: "ScanLink", targets: ["ScanLink"]),
    ],
    targets: [
        .target(name: "ScanLinkCore"),
        .target(name: "ScanLink", dependencies: ["ScanLinkCore"]),
        .testTarget(name: "ScanLinkCoreTests", dependencies: ["ScanLinkCore"]),
    ]
)
