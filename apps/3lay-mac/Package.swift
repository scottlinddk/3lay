// swift-tools-version: 5.9
import PackageDescription

// Not the way to run the app in Xcode: use `scripts/open-xcode.sh` (workspace with project.yml, which
// bundles Info.plist and convert_usdz.swift). `./build.sh` is the CI/release build. Neither uses this
// file; it compiles the same shared sources from packages/scan-link.
let package = Package(
    name: "ThreeLayMacOS",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ThreeLayMacOS", targets: ["ThreeLayMacOS"])
    ],
    dependencies: [
        .package(path: "../../packages/scan-link")
    ],
    targets: [
        .executableTarget(
            name: "ThreeLayMacOS",
            dependencies: [.product(name: "ScanLinkCore", package: "scan-link")],
            path: ".",
            exclude: [
                "shots",
                "MeshCheck.swift", "ReceiverCheck.swift", "PhotoQualityCheck.swift", "convert_usdz.swift", "MECHANICS.md",
                "README.md", "build.sh", "project.yml", "sources.sh", "mechanics.json", "rebuild_check", "package.json"
            ],
            sources: ["Mesh.swift", "UsdzConverter.swift", "PhotoReconstruction.swift", "PhotoQuality.swift", "LanAdvertiser.swift", "PhoneReceiver.swift", "ThreeLayMacOS.swift"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
