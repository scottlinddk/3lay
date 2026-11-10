import CoreGraphics
import Foundation
import simd
#if canImport(FoundationModels)
// Weak, so the app still launches on macOS 14 and 15, where this framework does not exist.
@_weakLinked import FoundationModels
#endif

/// Optional help from Apple's on-device model (Apple Intelligence, macOS 26 or later): reads measurements
/// of the scan and guesses what the object is and whether it is made of simple shapes.
///
/// The model gets numbers, not pictures. Image prompts exist only in the newest SDK and on the newest
/// on-device model, and the text form works on every macOS 26. A rebuild is a loop of measuring, modelling
/// and comparing over many rounds, which a small on-device model with a small context cannot do well; that
/// belongs to the agent that reads the scan package. Nothing leaves the Mac.
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
        /// Share of the surface that is flat and lined up with the X, Y or Z axis. A measurement, not a guess.
        let flatShare: Float
    }

    /// What the model is told about the scan.
    struct Facts {
        let size: SIMD3<Float>
        let triangles: Int
        let flatShare: Float

        var text: String {
            func mm(_ v: Float) -> String { String(format: "%.1f", Double(v)) }
            let longest = Swift.max(size.x, size.y, size.z), shortest = Swift.max(Swift.min(size.x, size.y, size.z), 0.001)
            return """
                Size: \(mm(size.x)) x \(mm(size.y)) x \(mm(size.z)) mm (width x depth x height), longest side \(String(format: "%.1f", Double(longest / shortest))) times the shortest.
                \(Int((flatShare * 100).rounded()))% of the surface is flat and faces along one of the three axes.
                The scan has \(triangles) triangles.
                """
        }
    }

    /// Area-weighted share of the surface whose normal is within about 10 degrees of an axis.
    static func flatShare(of mesh: Mesh) -> Float {
        var aligned: Double = 0, total: Double = 0
        for face in mesh.faces {
            guard face.x >= 0, face.y >= 0, face.z >= 0, face.x < mesh.vertices.count, face.y < mesh.vertices.count, face.z < mesh.vertices.count else { continue }
            let normal = simd_cross(mesh.vertices[face.y] - mesh.vertices[face.x], mesh.vertices[face.z] - mesh.vertices[face.x])
            let length = simd_length(normal)
            guard length > 0 else { continue }
            total += Double(length)
            if simd_reduce_max(simd_abs(normal)) / length > 0.985 { aligned += Double(length) }
        }
        return total > 0 ? Float(aligned / total) : 0
    }

    static func facts(of mesh: Mesh) -> Facts {
        Facts(size: mesh.bounds, triangles: mesh.faces.count, flatShare: flatShare(of: mesh))
    }

    /// Why the on-device model cannot be used here, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return Engine.unavailableReason }
        #endif
        return "Needs macOS 26 or later with Apple Intelligence."
    }

    static func describe(mesh: Mesh) async throws -> Suggestion {
        let facts = await Task.detached(priority: .userInitiated) { facts(of: mesh) }.value
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return try await Engine.describe(facts: facts) }
        #endif
        throw ScanError.message("Needs macOS 26 or later with Apple Intelligence.")
    }

    /// A short, single-line description fit for the description field.
    static func tidy(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(line.prefix(120))
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
    @Guide(description: "A guess at what the object is, in at most 12 words, for example: wall bracket with two screw holes. If the numbers do not say, describe its overall shape instead.")
    var summary: String
    @Guide(description: "mechanical: mostly flat faces along the axes, made by machine or mold. organic: sculpted, curved or natural. mixed: both.")
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

    static func describe(facts: OnDeviceDescriber.Facts) async throws -> OnDeviceDescriber.Suggestion {
        if let reason = unavailableReason { throw ScanError.message(reason) }
        let session = LanguageModelSession(instructions: """
            You are given measurements of a 3D scan of one real object. Guess what the object is and whether \
            it is made of simple shapes. You cannot see it, so be modest: if the numbers do not say what it is, \
            describe the overall shape instead of inventing a purpose.
            """)
        do {
            let response = try await session.respond(
                to: facts.text, generating: ScanReading.self, options: GenerationOptions(sampling: .greedy))
            let kind: OnDeviceDescriber.Suitability
            switch response.content.kind {
            case .mechanical: kind = .mechanical
            case .mixed: kind = .mixed
            case .organic: kind = .organic
            }
            return .init(summary: OnDeviceDescriber.tidy(response.content.summary), suitability: kind, flatShare: facts.flatShare)
        } catch {
            throw ScanError.message("The on-device model could not answer: \(error.localizedDescription)")
        }
    }
}
#endif
