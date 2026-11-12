#if os(iOS)
import CaptureKit
import SwiftUI

/// A view owns its request. Generation IDs prevent canceled, timed-out, or superseded work from publishing.
@MainActor
final class ScanCoachModel: ObservableObject {
    @Published private(set) var assessment: ScanAssessment?
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    func cancel(clear: Bool = false) {
        if clear { assessment = nil }
        requestID = UUID()
        task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        busy = false
    }

    func request(snapshot: ScanQualitySnapshot, folder: URL? = nil, enabled: Bool, images: Bool = false) {
        cancel()
        assessment = ScanAssessment(report: .init(snapshot: snapshot))
        status = "Measured guidance"
        defer { if !busy { persist(folder: folder) } }
        guard enabled else { return }
        guard ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else {
            status = "AI paused while the phone cools. Measured guidance is available."
            return
        }
        if let message = ScanAdvisor.availabilityMessage { status = message; return }
        let id = requestID
        busy = true
        status = "Assessing on this device…"
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(images ? 25 : 12)) } catch { return }
            guard let self, self.requestID == id else { return }
            self.cancel()
            self.status = "AI took too long. Showing measured guidance."
            self.assessment?.outcome = "timeout"
            self.persist(folder: folder)
        }
        task = Task { [weak self] in
            do {
                let result = try await ScanAdvisor.assess(snapshot, folder: folder, includeImages: images)
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.assessment = result
                self.status = result.report.source == "onDevice" ? "Prioritized on this device" : "Measured guidance"
                self.persist(folder: folder)
            } catch {
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.status = "AI is unavailable. Showing measured guidance."
                self.assessment?.outcome = "unavailableOrInvalid"
                self.persist(folder: folder)
            }
            guard let self, self.requestID == id else { return }
            self.watchdog?.cancel(); self.watchdog = nil
            self.busy = false
        }
    }

    private func persist(folder: URL?) {
        guard let folder, let assessment else { return }
        do { try ScanQualityFiles.save(assessment, named: ScanQualityFiles.reportName, folder: folder) }
        catch { status += " · Report could not be saved" }
    }

    deinit { task?.cancel(); watchdog?.cancel() }
}

struct ScanQualitySection: View {
    let snapshot: ScanQualitySnapshot
    let folder: URL
    @AppStorage("scanCoachEnabled") private var enabled = false
    @AppStorage("scanCoachImages") private var images = false
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coach = ScanCoachModel()

    var body: some View {
        Section {
            Text(snapshot.summary).font(.subheadline)
            ForEach(coach.assessment?.report.suggestions ?? snapshot.evidence.prefix(3).map { $0 }) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.action.instruction)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if (coach.assessment?.report.snapshot.evidence ?? snapshot.evidence).isEmpty {
                Text("No issues were flagged by the available measurements. Inspect the model before relying on it.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let assessment = coach.assessment, images && enabled {
                ForEach(assessment.visual) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(finding.instruction)
                        Text("AI observation · \(finding.image)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(assessment.visualStatus).font(.caption).foregroundStyle(.secondary)
            }
            if coach.busy { ProgressView("Assessing on this device…") }
            if enabled {
                Button("Refresh advice") { refresh() }.disabled(coach.busy)
                Text(coach.status).font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("Scan quality") } footer: {
            Text("Advice helps you capture better source data. It does not repair geometry or guarantee accuracy. For finished scans, use suggestions on your next capture. Enable on-device AI in Settings to prioritize advice.")
        }
        .onAppear { refresh() }
        .onChange(of: snapshot) { _, _ in refresh() }
        .onChange(of: enabled) { _, _ in refresh() }
        .onChange(of: images) { _, _ in refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } else { coach.cancel() } }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in refresh() }
        .onDisappear { coach.cancel() }
    }
    private func refresh() {
        guard scenePhase == .active else { coach.cancel(); return }
        var current = snapshot
        current.thermal = Diagnostics.sample().thermal
        coach.request(snapshot: current, folder: folder, enabled: enabled, images: images)
    }
}

/// Called only for meaningful capture events. Current camera warnings always take precedence.
struct LiveScanCoach: View {
    let snapshot: ScanQualitySnapshot
    let event: String
    let active: Bool
    @AppStorage("scanCoachEnabled") private var enabled = false
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coach = ScanCoachModel()
    @State private var lastRequest = Date.distantPast

    var body: some View {
        Group {
            if enabled, active, let item = coach.assessment?.report.suggestions.first,
               snapshot.evidence.contains(where: { $0.id == item.id && $0.action == item.action }) {
                Label(item.action.instruction, systemImage: "sparkles")
                    .font(.subheadline).accessibilityLabel("Scan coach: \(item.action.instruction)")
            }
        }
        .onChange(of: event) { _, _ in refresh() }
        .onChange(of: active) { _, value in if !value { coach.cancel(clear: true) } else { refresh() } }
        .onChange(of: enabled) { _, _ in refresh() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { coach.cancel(clear: true) } }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { coach.cancel(clear: true) }
        }
        .onDisappear { coach.cancel(clear: true) }
    }
    private func refresh() {
        guard enabled, active, scenePhase == .active, !event.isEmpty else { coach.cancel(clear: true); return }
        guard Date().timeIntervalSince(lastRequest) >= 20 else { coach.cancel(clear: true); return }
        lastRequest = Date()
        coach.request(snapshot: snapshot, enabled: true)
    }
}
#endif
