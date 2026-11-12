import Foundation

/// What a long operation is doing right now. Each stage is something that is actually happening, so
/// the screen never shows a percentage the app made up.
public enum OperationStage: Equatable, Sendable {
    case saving
    case preparing
    /// Bytes the receiver has acknowledged, out of the total.
    case sending(sent: Int64, total: Int64)
    case reconstructing(fraction: Double?)
    case uploading(done: Int, total: Int)

    public var title: String {
        switch self {
        case .saving: return "Saving"
        case .preparing: return "Preparing"
        case .sending: return "Sending"
        case .reconstructing: return "Building the model"
        case .uploading: return "Uploading"
        }
    }

    /// 0...1 when the stage can say how far along it is, otherwise nil (an indeterminate spinner).
    public var fraction: Double? {
        switch self {
        case .sending(let sent, let total): return total > 0 ? min(1, Double(sent) / Double(total)) : nil
        case .reconstructing(let fraction): return fraction
        case .uploading(let done, let total): return total > 0 ? min(1, Double(done) / Double(total)) : nil
        case .saving, .preparing: return nil
        }
    }
}

public enum OperationOutcome: Equatable {
    case succeeded(message: String)
    case failed(message: String)
    case cancelled
}

/// Owns the one long-running operation (saving, packing, sending, reconstructing) at a time.
///
/// - A second `start` while one runs is refused, so a double tap cannot start two sends.
/// - Every operation has an identity. Progress and completion from an operation that is no longer the
///   current one (cancelled, or replaced) are ignored, so a late callback cannot change another screen.
/// - Progress only moves forward within a stage, and is published at whole-percent steps, so the UI is
///   not rebuilt for every tiny change.
@MainActor
public final class OperationTracker: ObservableObject {
    public struct Operation: Equatable {
        public let id: UUID
        public var title: String
        public var scanId: UUID?
        public var stage: OperationStage
    }

    /// Passed to the work closure. Updates are dropped once the operation is no longer current.
    public struct Context: Sendable {
        let id: UUID
        weak var tracker: OperationTracker?
        public func update(_ stage: OperationStage) {
            guard let tracker else { return }
            Task { @MainActor in tracker.apply(stage, to: id) }
        }
    }

    @Published public private(set) var current: Operation?
    @Published public private(set) var outcome: OperationOutcome?
    private var task: Task<Void, Never>?

    public init() {}

    public var isRunning: Bool { current != nil }

    /// Starts `work`. Returns false (and does nothing) if an operation is already running.
    /// `work` returns the success message; throwing `CancellationError` or being cancelled gives `.cancelled`.
    @discardableResult
    public func start(
        title: String, scanId: UUID? = nil, stage: OperationStage = .preparing,
        work: @escaping @Sendable (Context) async throws -> String
    ) -> Bool {
        guard current == nil else { return false }
        let id = UUID()
        current = Operation(id: id, title: title, scanId: scanId, stage: stage)
        outcome = nil
        let context = Context(id: id, tracker: self)
        task = Task { [weak self] in
            let result: OperationOutcome
            do {
                let message = try await work(context)
                try Task.checkCancellation()  // finished only because it ignored a cancel: still cancelled
                result = .succeeded(message: message)
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = Task.isCancelled ? .cancelled : .failed(message: error.localizedDescription)
            }
            self?.finish(id, result)
        }
        return true
    }

    /// Asks the running operation to stop. The outcome arrives as `.cancelled`; the work closure is
    /// responsible for leaving the scan recoverable (nothing here deletes files).
    public func cancel() { task?.cancel() }

    public func acknowledgeOutcome() { outcome = nil }

    fileprivate func apply(_ stage: OperationStage, to id: UUID) {
        guard var operation = current, operation.id == id else { return }  // stale: ignore
        if Self.isBackward(from: operation.stage, to: stage) { return }
        guard Self.worthPublishing(from: operation.stage, to: stage) else { return }
        operation.stage = stage
        current = operation
    }

    private func finish(_ id: UUID, _ result: OperationOutcome) {
        guard current?.id == id else { return }
        current = nil
        task = nil
        outcome = result
    }

    // MARK: Rules (static so they can be tested directly)

    static func isBackward(from old: OperationStage, to new: OperationStage) -> Bool {
        switch (old, new) {
        case (.sending(let a, _), .sending(let b, _)): return b < a
        case (.uploading(let a, _), .uploading(let b, _)): return b < a
        case (.reconstructing(let a?), .reconstructing(let b?)): return b < a
        default: return false
        }
    }

    static func worthPublishing(from old: OperationStage, to new: OperationStage) -> Bool {
        guard let a = old.fraction, let b = new.fraction, old.title == new.title else { return true }
        return Int(b * 100) != Int(a * 100) || b >= 1
    }
}
