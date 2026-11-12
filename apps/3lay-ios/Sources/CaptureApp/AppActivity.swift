#if os(iOS)
import Foundation
import UIKit
import os

/// Whether the app may still use the GPU. iOS refuses GPU work from a backgrounded app and logs
/// `IOGPUMetalError: Insufficient Permission (to submit GPU work from background)`; a Core Image render
/// that is refused returns nil, so a photo would silently be lost. Work that can run either way checks
/// this and takes the CPU path instead.
///
/// Readable from any thread. The flag drops on `willResignActive`, which fires slightly before the app is
/// really backgrounded, so work that starts after it never races the system.
enum AppActivity {
    private static let active = OSAllocatedUnfairLock(initialState: true)
    private static let observers = OSAllocatedUnfairLock<[NSObjectProtocol]>(initialState: [])

    static var isActive: Bool { active.withLock { $0 } }

    /// Starts tracking the app's state. Safe to call more than once.
    static func start() {
        let alreadyStarted = observers.withLock { !$0.isEmpty }
        guard !alreadyStarted else { return }
        let center = NotificationCenter.default
        let resign = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
            active.withLock { $0 = false }
        }
        let become = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            active.withLock { $0 = true }
        }
        observers.withLock { $0 = [resign, become] }
        // The app may already be inactive when tracking starts.
        DispatchQueue.main.async {
            let isActive = UIApplication.shared.applicationState == .active
            active.withLock { $0 = isActive }
        }
    }
}
#endif
