#if os(iOS)
import CaptureKit
import SwiftUI

/// Progress for the running operation: what it is doing now, how far (only when that is known), and Cancel.
struct OperationView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { Content(operations: model.operations, cancel: model.cancelOperation) }

    private struct Content: View {
        @ObservedObject var operations: OperationTracker
        let cancel: () -> Void

        var body: some View {
            VStack(spacing: 16) {
                if let operation = operations.current {
                    Text(operation.title).font(.title3.bold())
                    stage(operation.stage)
                    Button("Cancel", role: .cancel, action: cancel)
                } else {
                    ProgressView()
                }
            }
            .padding()
            .accessibilityElement(children: .contain)
        }

        @ViewBuilder private func stage(_ stage: OperationStage) -> some View {
            if let fraction = stage.fraction {
                ProgressView(value: fraction) { Text(label(stage)) }
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            } else {
                ProgressView { Text(label(stage)) }
            }
        }

        private func label(_ stage: OperationStage) -> String {
            switch stage {
            case .sending(let sent, let total):
                let format = ByteCountFormatter()
                format.countStyle = .file
                return "Sending \(format.string(fromByteCount: sent)) of \(format.string(fromByteCount: total))"
            case .uploading(let done, let total): return "Uploading \(done) of \(total)"
            case .reconstructing(let fraction):
                return fraction.map { "Building the model on this phone… \(Int($0 * 100))%" } ?? "Building the model on this phone…"
            case .preparing: return "Preparing…"
            case .saving: return "Saving…"
            }
        }
    }
}
#endif
