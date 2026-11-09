import Foundation

/// Converts a USDZ scan to STL by running the bundled `convert_usdz.swift` script with the
/// system Swift toolchain (Xcode or Command Line Tools). Runs off the main thread.
enum UsdzConverter {
    static func convert(_ usdz: URL) async throws -> URL {
        let output = usdz.deletingPathExtension().appendingPathExtension("stl")
        let script = Bundle.main.resourcePath.map { "\($0)/convert_usdz.swift" } ?? "convert_usdz.swift"
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            process.arguments = [script, usdz.path, output.path]
            let errors = Pipe()
            process.standardError = errors
            do { try process.run() } catch {
                throw ScanError.message("Swift is not installed. Run xcode-select --install, then try again.")
            }
            let message = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: message.suffix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ScanError.message("USDZ conversion failed. \(detail)")
            }
            return output
        }.value
    }
}
