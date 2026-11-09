// swift-tools-version: 5.9
import PackageDescription

// Convenience for opening the app in Xcode. `./build.sh` is the supported build and does not use
// this file. It compiles the same shared sources from packages/scan-link directly.
let package = Package(
    name: "Scanbench",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Scanbench", targets: ["Scanbench"])
    ],
    dependencies: [
        .package(path: "../../packages/scan-link")
    ],
    targets: [
        .executableTarget(
            name: "Scanbench",
            dependencies: [.product(name: "ScanLinkCore", package: "scan-link")],
            path: ".",
            exclude: [
                ".build", ".cache", "build", "shots",
                "MeshCheck.swift", "ReceiverCheck.swift", "convert_usdz.swift", "MECHANICS.md",
                "README.md", "build.sh", "sources.sh", "mechanics.json", "rebuild_check", "package.json"
            ],
            sources: ["Mesh.swift", "UsdzConverter.swift", "LanAdvertiser.swift", "PhoneReceiver.swift", "Scanbench.swift"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
