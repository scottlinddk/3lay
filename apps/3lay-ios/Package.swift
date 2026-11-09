// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "3lay-ios",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "CaptureApp", targets: ["CaptureApp"]),
    ],
    dependencies: [
        // The LAN contract shared with the Mac app (apps/3lay-mac).
        .package(path: "../../packages/scan-link"),
    ],
    targets: [
        // Pure, unit-tested logic: bundle manifest, API client, resumable upload, submission.
        .target(name: "CaptureKit"),
        // SwiftUI + RealityKit Object Capture. Compiled for iOS only; empty elsewhere.
        .target(
            name: "CaptureApp",
            dependencies: ["CaptureKit", .product(name: "ScanLink", package: "scan-link")]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"], resources: [.copy("Fixtures")]),
    ]
)
