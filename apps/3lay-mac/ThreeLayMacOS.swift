import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(ScanLinkCore)
import ScanLinkCore  // SwiftPM builds; build.sh compiles the same sources straight into this target.
#endif

private let appBackground = Color(red: 0.071, green: 0.094, blue: 0.118)
private let panel = Color(red: 0.11, green: 0.141, blue: 0.169)
private let accent = Color(red: 0.435, green: 0.816, blue: 0.706)

struct CloudItem: Identifiable {
    let id: String
    let jobName: String
    let filename: String
    let size: Int
}

@MainActor final class ScanState: ObservableObject {
    @Published var mesh: Mesh?
    @Published var selection = 0
    @Published var scale: Double = 1
    @Published var angle: Double = 0
    @Published var status = "Ready for a scan"
    @Published var path = ""
    @Published var pairingLink = ""
    @Published var cloudItems: [CloudItem] = []
    @Published var phoneStatus = ""
    @Published var code: String
    @Published var advertisedName = ""
    let ip = PhoneReceiver.localIP()
    private(set) var port = LanProtocol.defaultPort
    private var phone: PhoneReceiver?
    private var advertiser: LanAdvertiser?
    private static let codeKey = "phonePairingCode"

    init() {
        // Keep the code between launches so a paired phone does not need it again each time.
        let saved = UserDefaults.standard.string(forKey: Self.codeKey)
        code = saved.flatMap { LanProtocol.isValidCode($0) ? $0 : nil } ?? Self.makeCode()
        UserDefaults.standard.set(code, forKey: Self.codeKey)
    }

    private static func makeCode() -> String { String(format: "%06d", Int.random(in: 100_000...999_999)) }

    /// A new code stops every phone that paired with the old one.
    func rotateCode() {
        code = Self.makeCode()
        UserDefaults.standard.set(code, forKey: Self.codeKey)
        phone?.code = code
    }

    func startPhone() {
        guard phone == nil else { return }
        do {
            let onFile: (URL) -> Void = { [weak self] url in DispatchQueue.main.async { self?.receive(url) } }
            // Bonjour tells phones the real port, so a busy 8765 (second copy, other app) is not fatal.
            let receiver = try (try? PhoneReceiver(code: code, onFile: onFile)) ?? PhoneReceiver(code: code, port: 0, onFile: onFile)
            phone = receiver
            port = receiver.port
            phoneStatus = "Ready on local Wi-Fi"
            let advertiser = LanAdvertiser(port: receiver.port)
            advertiser.onStatus = { [weak self] text in DispatchQueue.main.async { self?.advertisedName = text } }
            advertiser.start()
            self.advertiser = advertiser
        } catch { phoneStatus = "Receiver unavailable: \(error.localizedDescription)" }
    }

    /// A file that arrived from the phone. USDZ is converted to STL first, off the main thread.
    func receive(_ url: URL) {
        if LanProtocol.isCaptureArchive(url.lastPathComponent) { reconstruct(archive: url); return }
        guard url.pathExtension.lowercased() == "usdz" else { importFile(url); return }
        status = "Converting \(url.lastPathComponent)…"
        Task {
            do { importFile(try await UsdzConverter.convert(url)) } catch { status = "Phone import failed: \(error.localizedDescription)" }
        }
    }

    /// Photos from the phone. The Mac builds the model, which is faster and more detailed than
    /// the phone doing it. Progress shows in the status line.
    func reconstruct(archive: URL) {
        status = "Unpacking photos…"
        Task {
            do {
                let usdz = try await PhotoReconstruction.run(archive: archive) { fraction in
                    DispatchQueue.main.async { self.status = "Building model from photos… \(Int(fraction * 100))%" }
                }
                status = "Converting model…"
                let stl = try await UsdzConverter.convert(usdz)
                try? FileManager.default.removeItem(at: archive)  // photos can be hundreds of MB
                importFile(stl)
            } catch { status = "Photo import failed: \(error.localizedDescription)" }
        }
    }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let imported = try Mesh.load(url)
            mesh = imported
            selection = 1
            scale = 1
            path = url.path
            status = "Imported \(imported.name) · \(imported.faces.count) triangles"
        } catch { status = "Import failed: \(error.localizedDescription)" }
    }

    func exportSTL() {
        guard let mesh else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = "placed-scan.stl"
        save.allowedContentTypes = [UTType(filenameExtension: "stl")!]
        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            try mesh.saveSTL(url, scale: Float(scale), angle: Float(angle))
            status = "Exported \(url.path)"
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }

    private func pairing() throws -> (URL, String) {
        guard let link = URLComponents(string: pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)),
              link.scheme == "scan3d", link.host == "pair",
              let server = link.queryItems?.first(where: { $0.name == "server" })?.value,
              let token = link.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty, let url = URL(string: server),
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? ""))
        else { throw ScanError.message("Paste a valid scan3d://pair link from the companion app") }
        return (url, token)
    }

    private func get(_ url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ScanError.message("Companion server rejected the request") }
        guard data.count <= 100_000_000 else { throw ScanError.message("Mesh exceeds the 100 MB import limit") }
        return data
    }

    func findPhoneScans() {
        status = "Looking for companion scans…"
        Task {
            do {
                let (server, token) = try pairing()
                let jobsData = try await get(server.appending(path: "api/jobs"), token: token)
                guard let jobs = try JSONSerialization.jsonObject(with: jobsData) as? [[String: Any]] else { throw ScanError.message("Invalid job list") }
                var found: [CloudItem] = []
                for job in jobs {
                    guard let id = job["id"] as? String else { continue }
                    let data = try await get(server.appending(path: "api/jobs/\(id)/artifacts"), token: token)
                    guard let artifacts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
                    for artifact in artifacts {
                        guard let aid = artifact["id"] as? String, let filename = artifact["filename"] as? String,
                              ["stl", "obj", "ply", "usdz"].contains((filename as NSString).pathExtension.lowercased()) else { continue }
                        found.append(CloudItem(id: aid, jobName: job["name"] as? String ?? "Phone scan", filename: filename, size: artifact["size"] as? Int ?? 0))
                    }
                }
                cloudItems = found.reversed()
                status = "Found \(found.count) compatible phone scans"
            } catch { status = "Companion connection failed: \(error.localizedDescription)" }
        }
    }

    func importPhoneScan(_ item: CloudItem) {
        status = "Downloading \(item.filename)…"
        Task {
            do {
                guard item.size <= 100_000_000 else { throw ScanError.message("Mesh exceeds the 100 MB import limit") }
                let (server, token) = try pairing()
                let data = try await get(server.appending(path: "api/artifacts/\(item.id)/content"), token: token)
                let dir = PhoneReceiver.defaultInbox
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let filename = URL(fileURLWithPath: item.filename).lastPathComponent
                var file = dir.appending(path: "\(item.id)-\(filename)")
                try data.write(to: file, options: .atomic)
                if file.pathExtension.lowercased() == "usdz" { file = try await UsdzConverter.convert(file) }
                importFile(file)
            } catch { status = "Phone import failed: \(error.localizedDescription)" }
        }
    }
}

struct ThreeLayMacOSView: View {
    @StateObject private var state = ScanState()
    @State private var importing = false
    private let steps = [("01", "Bring in a scan", "Phone or file"), ("02", "Check size", "Confirm millimetres"), ("03", "Place on plate", "Rotate and inspect"), ("04", "Next steps", "Export and slice")]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("◈").font(.title).foregroundStyle(accent)
                Text("3LAY MAC").font(.headline).tracking(1)
                Text("Prepare your scan for printing").foregroundStyle(.secondary).padding(.leading, 15)
                Spacer()
                Text("LOCAL WORKSPACE").font(.caption).foregroundStyle(.secondary)
                Button("Import file") { importing = true }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(appBackground)
            }
            .padding(.horizontal, 20).frame(height: 62).background(panel)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("WORKFLOW").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 16)
                    ForEach(steps.indices, id: \.self) { i in
                        Button { state.selection = i } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(steps[i].0).foregroundStyle(state.selection == i ? accent : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(steps[i].1).foregroundStyle(.white).fontWeight(.semibold)
                                    Text(steps[i].2).foregroundStyle(.secondary).font(.caption)
                                }
                                Spacer()
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(state.selection == i ? accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                    Divider().padding(.vertical, 8)
                    Text("PHONE CONNECTION").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("● \(state.phoneStatus)").font(.caption).foregroundStyle(state.phoneStatus.hasPrefix("Ready") ? accent : .red)
                    Text("\(state.ip):\(String(state.port))").font(.caption)
                    Text("Code \(state.code)").font(.caption).foregroundStyle(.secondary)
                    if !state.advertisedName.isEmpty { Text(state.advertisedName).font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(.horizontal, 16).frame(width: 225).background(panel)

                PlateView(mesh: state.mesh, scale: state.scale, angle: state.angle) { delta in state.angle += delta }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                        guard let provider = providers.first else { return false }
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            if let url { DispatchQueue.main.async { state.importFile(url) } }
                        }
                        return true
                    }

                ScrollView { detail.padding(18).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(width: 315).background(panel)
            }
            HStack { Text("●").foregroundStyle(accent); Text(state.status).font(.caption); Spacer() }
                .padding(.horizontal, 20).frame(height: 36).background(panel)
        }
        .foregroundStyle(.white)
        .background(appBackground)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "stl")!, UTType(filenameExtension: "obj")!, UTType(filenameExtension: "ply")!]) { result in
            if case let .success(url) = result { state.importFile(url) }
        }
        .onAppear { state.startPhone() }
    }

    @ViewBuilder private var detail: some View {
        switch state.selection {
        case 0:
            Text("Import a scan").font(.title2.bold())
            Text("Send from your phone on the same Wi-Fi network, or choose a file.").foregroundStyle(.secondary)
            section("ON YOUR PHONE")
            Text("Open the 3lay iOS app, choose Nearby Mac, pick this Mac and enter the code. Then scan an object and send it here.").font(.caption).foregroundStyle(.secondary)
            Text("Pairing code  \(state.code)").font(.headline).foregroundStyle(accent)
            Button("New code") { state.rotateCode() }
            Text("A new code disconnects phones that used the old one.").font(.caption).foregroundStyle(.secondary)
            Text("No Mac in the list? Type this address on the phone, or open it in the phone's browser:").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            Text("\(state.ip):\(String(state.port))").foregroundStyle(accent).font(.headline)
            Button("Copy address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("http://\(state.ip):\(String(state.port))", forType: .string) }
            Divider().padding(.vertical, 10)
            section("FROM THIS COMPUTER")
            TextField("Path to .stl, .obj or .ply", text: $state.path)
            Button("Open this file") { state.importFile(URL(fileURLWithPath: state.path)) }
            Text("You can also drop a mesh anywhere on the plate.").font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 10)
            section("COMPANION APP")
            Text("Paste the pairing link used by the iPhone app to find scans on its server.").font(.caption).foregroundStyle(.secondary)
            SecureField("Paste scan3d://pair link", text: $state.pairingLink)
            Button("Find phone scans") { state.findPhoneScans() }
            ForEach(state.cloudItems) { item in
                HStack { Text("\(item.jobName) · \(item.filename)").font(.caption); Spacer(); Button("Import") { state.importPhoneScan(item) } }
            }
        case 1:
            Text("Check size").font(.title2.bold())
            Text("Scans do not always include reliable units. Measure the real object before printing.").foregroundStyle(.secondary)
            if let mesh = state.mesh {
                section("SOURCE DIMENSIONS")
                dimension("Width", mesh.bounds.x)
                dimension("Depth", mesh.bounds.y)
                dimension("Height", mesh.bounds.z)
                Text("Scale factor")
                Slider(value: $state.scale, in: 0.01...100)
                Text(state.scale.formatted(.number.precision(.fractionLength(2))))
                Text("Displayed dimensions are millimetres only after you confirm the scan's units.").font(.caption).foregroundStyle(.secondary)
            } else { Text("Import a scan to see its dimensions.").foregroundStyle(.secondary) }
        case 2:
            Text("Place on plate").font(.title2.bold())
            Text("Drag the model view to turn it. Adjust rotation around the upright axis here.").foregroundStyle(.secondary)
            section("ROTATION")
            Slider(value: $state.angle, in: -180...180)
            Text("\(Int(state.angle))°")
            Button("Reset view") { state.angle = 0 }
            section("PLATE PREVIEW")
            Text("256 × 256 mm visual guide. Confirm the actual printer profile before slicing.").font(.caption).foregroundStyle(.secondary)
        default:
            Text("Next steps").font(.title2.bold())
            Text("Review the size and orientation, then open the source mesh in a slicer to choose printer and material settings.").foregroundStyle(.secondary)
            if let mesh = state.mesh {
                Text("Loaded: \(mesh.name)")
                Button("Export placed STL") { state.exportSTL() }.buttonStyle(.borderedProminent).tint(accent)
            }
            Text("Exported STL carries no unit metadata. Mesh repair and slicing are not yet included.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func section(_ title: String) -> some View { Text(title).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 16) }
    private func dimension(_ title: String, _ value: Float) -> some View {
        HStack { Text(title); Spacer(); Text(String(format: "%.1f", Double(value) * state.scale)) }
    }
}

struct PlateView: View {
    let mesh: Mesh?
    let scale: Double
    let angle: Double
    let rotate: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let unit = max(0.3, min(size.width, size.height) / 460)
                func point(_ v: SIMD3<Float>) -> CGPoint {
                    CGPoint(x: size.width / 2 + CGFloat(v.x - v.y) * 0.72 * unit,
                            y: size.height / 2 + 45 + CGFloat(v.x + v.y) * 0.36 * unit - CGFloat(v.z) * 0.9 * unit)
                }
                let corners = [SIMD3<Float>(-128,-128,0), SIMD3<Float>(128,-128,0), SIMD3<Float>(128,128,0), SIMD3<Float>(-128,128,0)]
                var plate = Path()
                plate.move(to: point(corners[0]))
                for corner in corners.dropFirst() { plate.addLine(to: point(corner)) }
                plate.closeSubpath()
                context.fill(plate, with: .color(Color(red: 0.14, green: 0.20, blue: 0.22)))
                context.stroke(plate, with: .color(accent), lineWidth: 2)
                for i in -4...4 {
                    let t = Float(i) * 25.6
                    for (a, b) in [(SIMD3<Float>(t,-128,0), SIMD3<Float>(t,128,0)), (SIMD3<Float>(-128,t,0), SIMD3<Float>(128,t,0))] {
                        var line = Path(); line.move(to: point(a)); line.addLine(to: point(b))
                        context.stroke(line, with: .color(Color(red: 0.26, green: 0.33, blue: 0.34)), lineWidth: i == 0 ? 1 : 0.6)
                    }
                }
                if let mesh {
                    let a = Float(angle * .pi / 180), c = cos(a), s = sin(a)
                    let fit = min(1, 220 / max(1, max(mesh.bounds.x, mesh.bounds.y) * Float(scale)))
                    let transformed = mesh.vertices.map { v -> SIMD3<Float> in
                        let x = v.x * Float(scale) * fit, y = v.y * Float(scale) * fit
                        return SIMD3(x * c - y * s, x * s + y * c, v.z * Float(scale) * fit)
                    }
                    let step = max(1, mesh.faces.count / 6000)
                    let triangles = Swift.stride(from: 0, to: mesh.faces.count, by: step).compactMap { i -> (Float, [CGPoint])? in
                        let f = mesh.faces[i]
                        guard f.x >= 0, f.y >= 0, f.z >= 0, f.x < transformed.count, f.y < transformed.count, f.z < transformed.count else { return nil }
                        let vs = [transformed[f.x], transformed[f.y], transformed[f.z]]
                        return (vs.reduce(0) { $0 + $1.x + $1.y }, vs.map(point))
                    }.sorted { $0.0 < $1.0 }
                    for (_, points) in triangles {
                        var triangle = Path(); triangle.move(to: points[0]); triangle.addLine(to: points[1]); triangle.addLine(to: points[2]); triangle.closeSubpath()
                        context.fill(triangle, with: .color(Color(red: 0.43, green: 0.69, blue: 0.59)))
                        context.stroke(triangle, with: .color(Color(red: 0.18, green: 0.36, blue: 0.35)), lineWidth: 0.35)
                    }
                }
            }
            VStack { HStack { Text("BUILD PLATE · PERSPECTIVE"); Spacer() }; Spacer(); HStack { Text("Drag to rotate view  ·  256 × 256 mm guide"); Spacer() } }
                .font(.caption).foregroundStyle(.secondary).padding(24)
            if mesh == nil {
                VStack(spacing: 10) { Text("Drop a 3D scan here").font(.title3); Text("STL · OBJ · ASCII PLY").font(.caption).foregroundStyle(.secondary) }
                    .frame(width: 290, height: 100).background(panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2 - 22)
            }
        }
        .background(appBackground)
        .gesture(DragGesture().onChanged { rotate(Double($0.translation.width) * 0.03) })
    }
}

@main struct ThreeLayMacOSApp: App {
    var body: some Scene { WindowGroup("3lay Mac") { ThreeLayMacOSView().frame(minWidth: 920, minHeight: 600).frame(width: 1280, height: 800) } }
}
