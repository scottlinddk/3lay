import CoreGraphics
import Foundation
import simd
#if canImport(FoundationModels)
// Weak, so the app still launches on macOS 14 and 15, where this framework does not exist.
@_weakLinked import FoundationModels
#endif

/// Optional help from Apple's on-device model (Apple Intelligence, macOS 26 or later): looks at the scan
/// and suggests a one-line description and whether the object is made of simple shapes.
///
/// This is deliberately all it does. A rebuild is a loop of measuring, modelling and comparing over many
/// rounds with several pictures, which a small on-device model with a small context cannot do well;
/// that part belongs to the agent that reads the scan package. Nothing leaves the Mac.
enum OnDeviceDescriber {
    enum Suitability: String {
        case mechanical, mixed, organic

        var advice: String {
            switch self {
            case .mechanical: return "Looks made of simple shapes: a clean rebuild should work well."
            case .mixed: return "Partly simple shapes, partly free-form: a clean rebuild may leave out detail."
            case .organic: return "Looks sculpted or free-form: the scan is probably the better model to print."
            }
        }
    }

    struct Suggestion {
        let summary: String
        let suitability: Suitability
    }

    /// Why the on-device model cannot be used here, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return Engine.unavailableReason }
        #endif
        return "Needs macOS 26 or later with Apple Intelligence."
    }

    static func describe(mesh: Mesh) async throws -> Suggestion {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return try await Engine.describe(mesh: mesh) }
        #endif
        throw ScanError.message("Needs macOS 26 or later with Apple Intelligence.")
    }

    /// A short, single-line description fit for the description field.
    static func tidy(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(line.prefix(120))
    }

    /// Straight-on pictures for the model: two views, not the four of the package, to keep tokens down.
    static func pictures(of mesh: Mesh, size: Int = 512) -> [CGImage] {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for vertex in mesh.vertices { lo = simd_min(lo, vertex); hi = simd_max(hi, vertex) }
        let centre = (lo + hi) / 2
        let span = Swift.max(simd_length(hi - lo) * 1.08, 1e-3)
        return [MeshRender.views[3], MeshRender.views[1]].compactMap { view in
            MeshRender.cgImage(MeshRender.render(mesh, view: view, centre: centre, span: span, size: size), size: size)
        }
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
enum ScanKind {
    case mechanical
    case mixed
    case organic
}

@available(macOS 26.0, *)
@Generable
struct ScanReading {
    @Guide(description: "What the object is, in at most 12 words, for example: wall bracket with two screw holes")
    var summary: String
    @Guide(description: "mechanical: flat faces, straight edges, round holes, made by machine or mold. organic: sculpted, curved free-form or natural. mixed: both.")
    var kind: ScanKind
}

@available(macOS 26.0, *)
private enum Engine {
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
        case .unavailable(.modelNotReady): return "The on-device model is still downloading or not ready. Try again later."
        case .unavailable: return "Apple Intelligence is turned off or unavailable here. Check System Settings."
        }
    }

    static func describe(mesh: Mesh) async throws -> OnDeviceDescriber.Suggestion {
        if let reason = unavailableReason { throw ScanError.message(reason) }
        let images = OnDeviceDescriber.pictures(of: mesh)
        guard images.count == 2 else { throw ScanError.message("Could not draw the scan.") }
        let session = LanguageModelSession(instructions: """
            You look at shaded grey pictures of a 3D scan of a real object and say what it is. \
            Light grey surfaces face the viewer. Be brief and concrete. If you are not sure, say what it most resembles.
            """)
        do {
            let response = try await session.respond(
                generating: ScanReading.self, options: GenerationOptions(samplingMode: .greedy)
            ) {
                "These two pictures show one 3D scan, from the front right above, and from the front. What is the object?"
                Attachment(images[0])
                Attachment(images[1])
            }
            let kind: OnDeviceDescriber.Suitability
            switch response.content.kind {
            case .mechanical: kind = .mechanical
            case .mixed: kind = .mixed
            case .organic: kind = .organic
            }
            return .init(summary: OnDeviceDescriber.tidy(response.content.summary), suitability: kind)
        } catch {
            // Older on-device model versions take no images; the error says so in the system's words.
            throw ScanError.message("The on-device model could not read the pictures: \(error.localizedDescription)")
        }
    }
}
#endif
