import Foundation

/// Measurements, not a prediction of reconstruction quality. nil means unmeasured.
public struct ScanQualitySnapshot: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case object, lidar }
    public var version = 1
    public var mode: Mode
    public var photoCount: Int
    public var sampledFrames: Int?
    public var blurryFrames: Int?
    public var darkFrames: Int?
    public var trackingFrames: Int?
    public var fastFrames: Int?
    public var observedCoverage: Int?
    public var coveragePlateau: Bool?
    public var completedPass: Bool?
    public var feedback: [String]
    public var thermal: String

    public init(mode: Mode, photoCount: Int, sampledFrames: Int? = nil, blurryFrames: Int? = nil,
                darkFrames: Int? = nil, trackingFrames: Int? = nil, fastFrames: Int? = nil,
                observedCoverage: Int? = nil, coveragePlateau: Bool? = nil, completedPass: Bool? = nil,
                feedback: [String] = [], thermal: String = "unknown") {
        self.mode = mode; self.photoCount = max(0, photoCount)
        self.sampledFrames = sampledFrames; self.blurryFrames = blurryFrames; self.darkFrames = darkFrames
        self.trackingFrames = trackingFrames; self.fastFrames = fastFrames
        self.observedCoverage = mode == .lidar ? observedCoverage.flatMap { (0...100).contains($0) ? $0 : nil } : nil
        self.coveragePlateau = mode == .lidar ? coveragePlateau : nil
        self.completedPass = mode == .object ? completedPass : nil
        self.feedback = feedback; self.thermal = thermal
    }

    public var summary: String {
        if mode == .lidar, let coverage = observedCoverage {
            return "\(photoCount) photos. \(coverage)% of observed surfaces are well photographed. Unseen surfaces are not measured."
        }
        return "\(photoCount) photos. Overall completeness and reconstruction accuracy are not measured."
    }

    public var evidence: [ScanEvidence] {
        var result: [ScanEvidence] = []
        if thermal == "serious" || thermal == "critical" {
            result.append(.init(id: "thermal", action: .coolDown, detail: "The phone reported elevated thermal pressure."))
        }
        func frequent(_ count: Int?) -> Bool {
            guard let count, let total = sampledFrames, total >= 20 else { return false }
            return Double(count) / Double(total) >= 0.15
        }
        if frequent(darkFrames) || feedback.contains("dark") {
            result.append(.init(id: "exposure", action: .addLight, detail: "Long exposure or low-light feedback was recorded."))
        }
        if frequent(blurryFrames) || frequent(fastFrames) || feedback.contains("fast") {
            result.append(.init(id: "motion", action: .holdSteady, detail: "Blur or excessive motion was recorded."))
        }
        if frequent(trackingFrames) {
            result.append(.init(id: "tracking", action: .improveTracking, detail: "Tracking was limited in at least 15% of evaluated frames."))
        }
        if feedback.contains("close") {
            result.append(.init(id: "distance-close", action: .moveBack, detail: "Object Capture reported the object was too close."))
        } else if feedback.contains("far") {
            result.append(.init(id: "distance-far", action: .moveCloser, detail: "Object Capture reported the object was too far away."))
        }
        if feedback.contains("outOfView") {
            result.append(.init(id: "framing", action: .centerObject, detail: "Object Capture reported the object outside the frame."))
        }
        if mode == .object, photoCount < Submission.minimumPhotos {
            result.append(.init(id: "photo-count", action: .morePhotos, detail: "Fewer than \(Submission.minimumPhotos) photos were captured."))
        }
        if mode == .lidar, let coverage = observedCoverage, coverage < 85 {
            result.append(.init(id: "coverage", action: .coverObservedSurfaces, detail: "Some observed surfaces still need better photos; unseen surfaces are unknown."))
        }
        if mode == .lidar, coveragePlateau == true {
            result.append(.init(id: "plateau", action: .changeViewpoint, detail: "Measured photo coverage stopped improving."))
        }
        if mode == .object, completedPass == true {
            result.append(.init(id: "scan-pass", action: .anotherPass, detail: "Object Capture reported a completed scan pass."))
        }
        return result
    }
}

public struct ScanEvidence: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var action: ScanAdviceAction
    public var detail: String
}

public enum ScanAdviceAction: String, Codable, CaseIterable, Sendable {
    case coolDown, addLight, holdSteady, improveTracking, moveBack, moveCloser, centerObject
    case morePhotos, coverObservedSurfaces, changeViewpoint, anotherPass
    public var instruction: String {
        switch self {
        case .coolDown: return "Let the phone cool before continuing."
        case .addLight: return "Add soft, even light before taking more photos."
        case .holdSteady: return "Move slowly and hold the phone steadier."
        case .improveTracking: return "Move slowly and keep textured surfaces in view."
        case .moveBack: return "Move back a little to keep the object in focus."
        case .moveCloser: return "Move closer while keeping the whole object in view."
        case .centerObject: return "Keep the object inside the camera frame."
        case .morePhotos: return "Capture more overlapping views around the object."
        case .coverObservedSurfaces: return "Photograph the highlighted surfaces from another angle."
        case .changeViewpoint: return "Try a different height or angle instead of repeating the same path."
        case .anotherPass: return "Consider another lap from a different height to capture more detail."
        }
    }
}

/// Counts the first rejection reason for each evaluated frame. These are not independent defect rates.
public struct ScanQualityAccumulator: Sendable {
    public private(set) var frames = 0
    private var blurry = 0, dark = 0, tracking = 0, fast = 0
    public init() {}
    public mutating func record(_ decision: CapturePolicy.Decision) {
        frames += 1
        guard case .skip(let reason) = decision else { return }
        switch reason {
        case .blurry: blurry += 1
        case .longExposure: dark += 1
        case .tracking: tracking += 1
        case .tooFast: fast += 1
        default: break
        }
    }
    public func snapshot(photoCount: Int, coverage: Int?, plateau: Bool, thermal: String) -> ScanQualitySnapshot {
        .init(mode: .lidar, photoCount: photoCount, sampledFrames: frames, blurryFrames: blurry,
              darkFrames: dark, trackingFrames: tracking, fastFrames: fast,
              observedCoverage: coverage, coveragePlateau: plateau, thermal: thermal)
    }
}

public struct ScanAdviceSelection: Sendable {
    public var action: ScanAdviceAction
    public var evidenceID: String
    public init(action: ScanAdviceAction, evidenceID: String) { self.action = action; self.evidenceID = evidenceID }
}

public struct ScanQualityReport: Codable, Equatable, Sendable {
    public var version = 1
    public var snapshot: ScanQualitySnapshot
    public var suggestions: [ScanEvidence]
    public var source: String
    public var createdAt = Date()
    public init(snapshot: ScanQualitySnapshot, selections: [ScanAdviceSelection]? = nil) {
        self.snapshot = snapshot
        let evidence = snapshot.evidence
        let validated = selections.map { values in
            values.compactMap { value in evidence.first { $0.id == value.evidenceID && $0.action == value.action } }
        }
        // Reject the entire response on unsupported evidence, duplicate selections, or omissions of urgent heat guidance.
        if let selections, let validated, !validated.isEmpty, validated.count == selections.count,
           validated.count <= 3, Set(validated.map(\.id)).count == validated.count,
           evidence.first?.action != .coolDown || validated.first?.action == .coolDown {
            suggestions = validated; source = "onDevice"
        } else {
            suggestions = Array(evidence.prefix(3)); source = "measured"
        }
    }
}

public enum ScanQualityFiles {
    public static let snapshotName = "scan-quality.json"
    public static let reportName = "scan-advice.json"
    public static func save<T: Encodable>(_ value: T, named name: String, folder: URL) throws {
        // Do not recreate a scan folder after deletion/cancellation.
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try JSONEncoder().encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
    }
    public static func loadSnapshot(folder: URL) -> ScanQualitySnapshot? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(snapshotName)),
              let value = try? JSONDecoder().decode(ScanQualitySnapshot.self, from: data), value.version == 1 else { return nil }
        return value
    }
    public static func photoURLs(folder: URL, mode: ScanQualitySnapshot.Mode) -> [URL] {
        let directory = folder.appendingPathComponent(mode == .lidar ? "photos" : "Images")
        return ((try? FileManager.default.contentsOfDirectory(at: directory,
                 includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? [])
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return ["jpg", "jpeg", "heic", "png"].contains(url.pathExtension.lowercased())
                    && values?.isRegularFile == true && values?.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    public static func representativeIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return Array(Set([0, count / 2, count - 1])).sorted()
    }
}
