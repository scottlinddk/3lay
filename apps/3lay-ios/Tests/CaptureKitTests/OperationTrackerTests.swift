import XCTest
@testable import CaptureKit

@MainActor
final class OperationTrackerTests: XCTestCase {
    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    func testSecondStartIsRefusedWhileRunning() async {
        let tracker = OperationTracker()
        let gate = AsyncStream<Void>.makeStream()
        XCTAssertTrue(tracker.start(title: "a") { _ in for await _ in gate.stream { break }; return "done" })
        XCTAssertFalse(tracker.start(title: "b") { _ in "never" })
        gate.continuation.yield()
        while tracker.isRunning { await Task.yield() }
        XCTAssertEqual(tracker.outcome, .succeeded(message: "done"))
    }

    func testCancelReportsCancelledAndFreesTheTracker() async {
        let tracker = OperationTracker()
        tracker.start(title: "send") { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return "unreachable"
        }
        await settle()
        tracker.cancel()
        while tracker.isRunning { await Task.yield() }
        XCTAssertEqual(tracker.outcome, .cancelled)
        XCTAssertTrue(tracker.start(title: "again") { _ in "ok" })
    }

    func testFailureCarriesTheMessage() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let tracker = OperationTracker()
        tracker.start(title: "x") { _ in throw Boom() }
        while tracker.isRunning { await Task.yield() }
        XCTAssertEqual(tracker.outcome, .failed(message: "boom"))
    }

    func testStaleProgressFromAFinishedOperationIsIgnored() async {
        let tracker = OperationTracker()
        let box = ContextBox()
        tracker.start(title: "first") { context in await box.set(context); return "ok" }
        while tracker.isRunning { await Task.yield() }
        let old = await box.value!
        let gate = AsyncStream<Void>.makeStream()
        tracker.start(title: "second", stage: .preparing) { _ in for await _ in gate.stream { break }; return "ok" }
        old.update(.sending(sent: 5, total: 10))  // from the first operation: must not touch the second
        await settle()
        XCTAssertEqual(tracker.current?.stage, .preparing)
        gate.continuation.yield()
        while tracker.isRunning { await Task.yield() }
    }

    func testProgressOnlyMovesForwardAndPerWholePercent() {
        XCTAssertTrue(OperationTracker.isBackward(from: .sending(sent: 50, total: 100), to: .sending(sent: 40, total: 100)))
        XCTAssertFalse(OperationTracker.isBackward(from: .preparing, to: .sending(sent: 0, total: 100)))
        XCTAssertFalse(OperationTracker.worthPublishing(from: .sending(sent: 500, total: 100_000), to: .sending(sent: 509, total: 100_000)))
        XCTAssertTrue(OperationTracker.worthPublishing(from: .sending(sent: 500, total: 100_000), to: .sending(sent: 1500, total: 100_000)))
        XCTAssertNil(OperationStage.preparing.fraction)
        XCTAssertEqual(OperationStage.sending(sent: 1, total: 4).fraction, 0.25)
    }

    private actor ContextBox {
        var value: OperationTracker.Context?
        func set(_ c: OperationTracker.Context) { value = c }
    }
}
