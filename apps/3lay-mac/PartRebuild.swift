import Foundation
import Security
import simd

/// The optional second path for a scan: instead of the scanned triangles, a clean part made of
/// simple solids (boxes, cylinders, outlines) that Claude writes after looking at the scan.
///
/// Each round Claude gets shaded straight-on views of the scan with their scale, then of its own
/// last attempt, plus measured distances between the two. The Mac builds every attempt, measures it
/// against the scan and keeps the closest. Good for mechanical parts; a figurine or anything with
/// relief is better left as the scan, and the measured deviation says so.
enum PartRebuild {
    struct Outcome {
        /// Closed mesh, in the same position and units as the scan.
        let mesh: Mesh
        let shape: SolidShape
        let notes: String
        let fit: ShapeFit
        let rounds: Int
    }

    static let defaultRounds = 3
    private static let viewSize = 448

    /// `progress` gets one line per step. Only pictures of the scan's shape, its measurements and
    /// `note` are sent; the photos never leave the Mac.
    static func run(scan: Mesh, note: String, apiKey: String, rounds: Int = defaultRounds,
                    progress: @escaping (String) -> Void) async throws -> Outcome {
        guard !scan.vertices.isEmpty else { throw ScanError.message("There is no scan to rebuild.") }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for vertex in scan.vertices { lo = simd_min(lo, vertex); hi = simd_max(hi, vertex) }
        let size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        let centre = (lo + hi) / 2
        let span = simd_length(hi - lo) * 1.08
        let pad = SIMD3<Float>(repeating: size * 0.12)

        func pictures(_ mesh: Mesh) throws -> [Data] {
            try MeshRender.views.map { view in
                guard let png = MeshRender.png(MeshRender.render(mesh, view: view, centre: centre, span: span, size: viewSize), size: viewSize)
                else { throw ScanError.message("Could not draw the \(view.name) view.") }
                return png
            }
        }
        func labelled(_ pngs: [Data], _ what: String) -> [ClaudeClient.Block] {
            zip(MeshRender.views, pngs).flatMap { view, png in
                [ClaudeClient.Block.text("\(what), \(view.caption):"), .png(png)]
            }
        }

        progress("Drawing the scan…")
        let scanPictures = try pictures(scan)
        var intro = "The scan fills X \(mm(lo.x)) to \(mm(hi.x)), Y \(mm(lo.y)) to \(mm(hi.y)), Z \(mm(lo.z)) to \(mm(hi.z)) "
            + "(\(mm(hi.x - lo.x)) × \(mm(hi.y - lo.y)) × \(mm(hi.z - lo.z)) mm). It stands on Z = 0.\n"
            + "Every picture is \(mm(span)) mm wide and high (\(String(format: "%.3f", Double(span) / Double(viewSize))) mm per pixel), "
            + "centred on (\(mm(centre.x)), \(mm(centre.y)), \(mm(centre.z))). Light grey faces the viewer, dark grey is steep.\n"
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { intro += "The person who scanned it says: \"\(trimmed.prefix(500))\"\n" }

        var best: (shape: SolidShape, notes: String, fit: ShapeFit)?
        var feedback: [ClaudeClient.Block] = []
        var lastProblem = "no attempt could be built"
        var used = 0
        for round in 1...max(1, rounds) {
            used = round
            progress("Rebuilding as a clean part: asking Claude (round \(round) of \(rounds))…")
            let reply = try await ClaudeClient.send(
                system: systemPrompt, blocks: [ClaudeClient.Block.text(intro)] + labelled(scanPictures, "The scan") + feedback, apiKey: apiKey)
            progress("Rebuilding as a clean part: measuring round \(round) against the scan…")
            do {
                let document = try SolidDocument.parse(reply: reply)
                let shape = try SolidShape(document.shape)
                let draft = SolidMesher.mesh(shape, lo: lo - pad, hi: hi + pad, cells: 96, name: "draft")
                guard !draft.faces.isEmpty else { throw ScanError.message("The shape is empty inside the scan's volume. Check its position against the scan's X, Y and Z ranges.") }
                let fit = ShapeFit.measure(shape: shape, scan: scan, model: draft)
                if best == nil || fit.score < best!.fit.score { best = (shape, document.notes ?? "", fit) }
                if fit.score < size * 0.006 { break }
                feedback = [ClaudeClient.Block.text("Your previous attempt:\n\(compact(document))\n\n\(report(fit))\nHere is that attempt, drawn the same way as the scan. Compare each view with the scan's, fix the largest difference first, and reply with the complete corrected JSON.")]
                    + labelled(try pictures(draft), "Your attempt")
            } catch {
                lastProblem = error.localizedDescription
                feedback = [ClaudeClient.Block.text("Your previous reply could not be used: \(lastProblem) Reply with the complete corrected JSON only.")]
            }
        }
        guard let best else { throw ScanError.message("No usable part came back (\(lastProblem)).") }
        progress("Building the clean part…")
        let mesh = SolidMesher.mesh(best.shape, lo: lo - pad, hi: hi + pad, cells: 224, name: "Rebuilt part")
        return Outcome(mesh: mesh, shape: best.shape, notes: best.notes, fit: best.fit, rounds: used)
    }

    private static func mm(_ value: Float) -> String { String(format: "%.1f", Double(value)) }

    private static func compact(_ document: SolidDocument) -> String {
        (try? JSONEncoder().encode(document)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The measured differences, in words Claude can act on.
    static func report(_ fit: ShapeFit) -> String {
        var text = "Measured against the scan: the scan's surface is on average \(mm(fit.meanScanToModel)) mm from your surface "
            + "(95% of it within \(mm(fit.p95ScanToModel)) mm). "
        if abs(fit.bias) > fit.meanScanToModel * 0.5 {
            text += fit.bias > 0 ? "Most of the scan lies outside your part, so it is too small or misplaced. " : "Most of the scan lies inside your part, so it is too big or is missing cut-outs. "
        }
        text += "Your surface is on average \(mm(fit.meanModelToScan)) mm from the scan (large means you added material the scan does not have).\n"
        if !fit.worst.isEmpty {
            text += "Largest differences:\n" + fit.worst.map {
                "- at (\(mm($0.point.x)), \(mm($0.point.y)), \(mm($0.point.z))) the scan's surface is \(mm(abs($0.signed))) mm \($0.signed > 0 ? "outside your part (material is missing there)" : "inside your part (there is a hole, recess or too much material there)")"
            }.joined(separator: "\n") + "\n"
        }
        return text
    }

    static let systemPrompt = """
        You turn a 3D scan of a real, manufactured object into a clean solid model for 3D printing. \
        The scan is a noisy triangle mesh: flat faces are slightly bumpy, sharp edges are rounded off \
        and small holes may be partly filled. Your model replaces it, so it has to match the real \
        object's size and features, with the noise left out.

        You are shown shaded pictures of the scan taken straight on, without perspective, together \
        with its measurements. Work out sizes from the pictures and their scale. Coordinates are \
        millimetres, Z is up, and the object stands on Z = 0.

        Describe the object as a tree of simple solids in JSON:

        {"notes": "one or two sentences: what the object is and what you were unsure about",
         "shape": NODE}

        A NODE is one of these. Every node may have "center": [x, y, z] (default 0, 0, 0) and \
        "rotate": [x, y, z] in degrees, turned about X first, then Y, then Z, about the node's centre.
        {"op": "box", "size": [x, y, z], "round": optional edge radius}
        {"op": "cylinder", "radius": r, "height": h}                      axis along Z
        {"op": "cone", "radius1": bottom, "radius2": top, "height": h}    axis along Z
        {"op": "sphere", "radius": r}
        {"op": "torus", "major": R, "minor": r}                            ring lying in the XY plane
        {"op": "extrude", "points": [[x, y], ...], "height": h}            closed outline in XY, extruded along Z
        {"op": "union", "children": [NODE, ...]}
        {"op": "subtract", "children": [NODE, NODE, ...]}                  the first child minus all the others
        {"op": "intersect", "children": [NODE, ...]}
        Solids are centred on their "center": a box of height 20 standing on Z = 0 has center z = 10.

        How to model well:
        - Prefer the simplest shape the pictures support: flat faces, right angles, round holes. \
        Use "extrude" for a profile that is the same all the way through, such as an L bracket.
        - Take dimensions from the scan. Round to a tidy number only when the measurement is within \
        about 1% of it.
        - Model only features you can see in the pictures. Do not add holes, chamfers or text you \
        are guessing at. Say what you left out in "notes".
        - Cut holes with a subtracted solid a little longer than the wall, so it goes right through.
        - If the object is organic or sculpted and simple solids cannot describe it, model its \
        overall form as well as you can and say so in "notes".

        Reply with the JSON object only.
        """
}

/// One request to the Claude Messages API. Swift has no official Anthropic SDK, so this is plain HTTPS.
enum ClaudeClient {
    enum Block {
        case text(String)
        case png(Data)
    }

    static let model = "claude-opus-5-5"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Returns the text of the reply.
    static func send(system: String, blocks: [Block], apiKey: String) async throws -> String {
        let content: [[String: Any]] = blocks.map { block in
            switch block {
            case .text(let text): return ["type": "text", "text": text]
            case .png(let data): return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": data.base64EncodedString()]]
            }
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 24_000,
            "output_config": ["effort": "high"],
            // If a safety check declines the request, the API reruns it on another model by itself.
            "fallbacks": "default",
            "system": system,
            "messages": [["role": "user", "content": content]],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw ScanError.message("Could not reach Claude: \(error.localizedDescription)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            switch status {
            case 401, 403: throw ScanError.message("Claude did not accept the API key. Check it under Clean rebuild. (\(detail))")
            case 429: throw ScanError.message("Claude is rate limiting this key. Wait a minute and try again. (\(detail))")
            case 500...: throw ScanError.message("Claude is unavailable right now. Try again in a moment. (\(detail))")
            default: throw ScanError.message("Claude refused the request: \(detail)")
            }
        }
        let stop = json?["stop_reason"] as? String
        if stop == "refusal" { throw ScanError.message("Claude declined to model this scan.") }
        let text = ((json?["content"] as? [[String: Any]]) ?? [])
            .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw ScanError.message(stop == "max_tokens" ? "Claude ran out of room before answering. Try again." : "Claude sent an empty reply.")
        }
        return text
    }
}

/// The Anthropic API key, kept in the login keychain. Never written to preferences or logs.
enum ApiKeyStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.craftanything.threelaymacos.anthropic",
        kSecAttrAccount as String: "api-key",
    ]

    static func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    static func save(_ key: String) throws {
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ScanError.message("The key could not be saved in the keychain (\(status)).") }
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}
