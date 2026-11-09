#if os(iOS)
import RealityKit
import SwiftUI  // ObjectCaptureSession lives in the RealityKit + SwiftUI overlay

@MainActor
enum ObjectCaptureAvailability {
    /// Object Capture on iOS needs a LiDAR device. Check at runtime, never by model name.
    static var isSupported: Bool { ObjectCaptureSession.isSupported }
}
#endif
