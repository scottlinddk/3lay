import Foundation
import ModelIO

let arguments = CommandLine.arguments
if arguments.count != 3 {
    fputs("Usage: convert_usdz.swift input.usdz output.stl\n", stderr)
    exit(2)
}
let source = URL(fileURLWithPath: arguments[1])
let target = URL(fileURLWithPath: arguments[2])

func parseArray(_ name: String, in text: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let pattern = "(?s)" + escaped + "\\s*=\\s*\\[([^\\]]*)\\]"
    guard let re = try? NSRegularExpression(pattern: pattern),
          let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}
func numbers(_ text: String) -> [Double] {
    let re = try! NSRegularExpression(pattern: "[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?[0-9]*)(?:[eE][-+]?[0-9]+)?")
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        guard let range = Range($0.range, in: text) else { return nil }
        return Double(text[range])
    }
}
func convertUSDText() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/usdcat")
    process.arguments = ["-f", source.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, data.count <= 150_000_000,
          let text = String(data: data, encoding: .utf8),
          let pointsText = parseArray("point3f[] points", in: text) ?? parseArray("point3d[] points", in: text),
          let countsText = parseArray("int[] faceVertexCounts", in: text),
          let indicesText = parseArray("int[] faceVertexIndices", in: text)
    else { throw NSError(domain: "ThreeLayMacOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "USDZ has no supported surface mesh"]) }
    let coordinates = numbers(pointsText).map(Float.init)
    let counts = numbers(countsText).map(Int.init)
    let indices = numbers(indicesText).map(Int.init)
    guard coordinates.count.isMultiple(of: 3), coordinates.count >= 9,
          counts.reduce(0,+) <= indices.count else { throw NSError(domain: "ThreeLayMacOS", code: 2, userInfo: [NSLocalizedDescriptionKey: "USDZ mesh arrays are incomplete"]) }
    var triangles: [[Int]] = []
    var cursor = 0
    for count in counts {
        guard count >= 0, cursor + count <= indices.count else { throw NSError(domain: "ThreeLayMacOS", code: 3) }
        if count >= 3 {
            for i in 1..<(count-1) { triangles.append([indices[cursor], indices[cursor+i], indices[cursor+i+1]]) }
        }
        cursor += count
    }
    guard triangles.count <= Int(UInt32.max) else { throw NSError(domain: "ThreeLayMacOS", code: 4) }
    var bytes = Data(repeating: 0, count: 80)
    func appendUInt32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) } }
    func appendFloat(_ value: Float) { appendUInt32(value.bitPattern) }
    appendUInt32(UInt32(triangles.count))
    for triangle in triangles {
        bytes.append(Data(repeating: 0, count: 12))
        for index in triangle {
            guard index >= 0, index * 3 + 2 < coordinates.count else { throw NSError(domain: "ThreeLayMacOS", code: 5) }
            appendFloat(coordinates[index*3]); appendFloat(coordinates[index*3+1]); appendFloat(coordinates[index*3+2])
        }
        bytes.append(contentsOf: [0,0])
    }
    try bytes.write(to: target)
}

let asset = MDLAsset(url: source)
if asset.count > 0 {
    do {
        try asset.export(to: target)
        print(target.path)
        exit(0)
    } catch { /* Try the USD text path below. */ }
}
do {
    try convertUSDText()
    print(target.path)
} catch {
    fputs("USDZ conversion failed: \(error.localizedDescription)\n", stderr)
    exit(4)
}
