import Foundation

/// Serializes inference across capture and review. Cancellation keeps the slot occupied until the
/// provider actually exits; a canceled provider can never overlap a replacement request.
public actor ScanAdviceRunner {
    public enum Failure: Error { case busy, timeout, suspended }
    private var busy = false
    private var suspensions = 0
    private var cancelActive: (@Sendable () -> Void)?
    private var waitForActive: (@Sendable () async -> Void)?
    public init() {}

    public func run<T: Sendable>(timeout: Duration = .seconds(12),
                                operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard suspensions == 0 else { throw Failure.suspended }
        guard !busy else { throw Failure.busy }
        busy = true
        let work = Task {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw Failure.timeout
                }
                defer { group.cancelAll() }
                let result = try await group.next()!
                try Task.checkCancellation()
                return result
            }
        }
        cancelActive = { work.cancel() }
        waitForActive = { _ = await work.result }
        defer { busy = false; cancelActive = nil; waitForActive = nil }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: { work.cancel() }
    }

    /// Reconstruction gets exclusive resources. Wait for inference to release its model first.
    public func withSuspended<T: Sendable>(operation: @escaping @Sendable () async throws -> T) async throws -> T {
        suspensions += 1
        defer { suspensions -= 1 }
        cancelActive?()
        await waitForActive?()
        try Task.checkCancellation()
        return try await operation()
    }
}
