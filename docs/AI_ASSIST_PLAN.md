# Plan: AI assist for higher-accuracy 3D objects

Status: **proposal, nothing implemented.** Written 2026-11-12. Items marked *(verify)* are claims read from
secondary sources; check them against Apple's, Anthropic's and OpenAI's own documentation before work starts.

## 1. What AI can and cannot do here

A language or vision model does not produce millimetre-accurate geometry. Accuracy in 3lay comes from the
photos, the LiDAR depth, the camera poses and Object Capture. A model that "looks at the scan" cannot add
precision that is not in that data, and a number it states (a size, a tolerance) is a guess, not a measurement.

So the goal is not "let the AI make the 3D object". It is to use a model for the **decisions around the
reconstruction**, then check with measurements whether those decisions helped:

| # | Role | Accuracy gain | Model does | Code does |
| --- | --- | --- | --- | --- |
| A | **Triage before reconstruction** | Drop bad inputs, pick better settings | Classify object and scene: glossy, transparent, textureless, thin parts, clutter, hand in frame, glare | Validate the answer, clamp to a whitelist of settings, apply them |
| B | **Scale cross-check** | Catch a wrong scale early | Read printed text, labels, barcodes, recognise a product | Compare with measured extents, flag a mismatch, ask the user. Never overwrite the measured scale |
| C | **Post-reconstruction QA** | Find holes, fused features, missing thin parts, then rescan | Compare mesh renders with source photos, list defects with a view index | Render the views, keep the list advisory, offer "rescan from these angles" |
| D | **Capture coach** (later) | Better coverage at capture time | Phrase guidance | ARKit/Vision decide coverage and sharpness (no model needed for that) |
| E | **Primitive hint** (research) | Snap to exact shapes | Suggest "cylinder with four holes" | A RANSAC fit decides whether it holds |

Out of scope: a model generating or editing meshes, a model deciding dimensions, sending whole bundles or depth maps.

Expect the biggest accuracy gains from non-AI work already on the backlog: using LiDAR depth for scale and
alignment on the Mac (not used yet, see `docs/LIDAR_BUNDLE.md`), object masking, and better capture coverage.
The AI steps are worth doing only if they beat that on the fixtures, so they are measured against it (section 7).

## 2. Three tiers, one contract

```
Tier 0  deterministic   existing PhotoQuality, OrientedExtents, depth coverage. Always on.
Tier 1  on-device       Apple Foundation Models (FoundationModels framework). Private, free, offline.
Tier 2  cloud           Claude or ChatGPT. Opt-in per scan, best quality, costs money, leaves the device.
```

All tiers sit behind one protocol and return the same schema, so the rest of the app never knows which ran.

```swift
protocol ScanAdvisor {
    var id: AdvisorID { get }                       // "apple-foundation", "anthropic", "openai"
    func advise(_ request: AdviceRequest) async throws -> ScanAdvice
}
```

`ScanAdvice/1` (JSON, schema-validated, written beside the model as `<name>.advice.json`):

```
{ schema, advisor{id, model, version}, promptVersion, createdAt,
  object{ kind, surface[glossy|transparent|textureless|textured], thinParts: Bool, notes },
  inputIssues[ {photo, issue[blur|glare|clutter|occlusion|duplicate], confidence} ],
  settings{ detail?, featureSensitivity?, dropPhotos[] },        // whitelisted, bounded
  scaleCheck{ evidence?, impliedMillimeters?, confidence },       // advisory only
  defects[ {view, kind[hole|fused|missing|floating|noisy], region, confidence} ],
  rescanSuggestions[ string ] }
```

Rules that make this safe to automate:

1. **Advisory by default.** Settings are applied only inside a whitelist (detail level, feature sensitivity, photos
   to set aside, never below the existing minimum of 20 photos). Anything else is shown, not applied.
2. **Structured output only.** Foundation Models `@Generable`; JSON-schema output for Claude and OpenAI
   *(verify current parameter names)*. Reject and retry once on invalid output, then fall back to Tier 0.
3. **As deterministic as the API allows**: temperature 0 where supported; model and prompt version recorded in the sidecar.
4. **Numbers from a model are never trusted.** `impliedMillimeters` only triggers a question to the user.

## 3. Where each tier runs

| Tier | Runs on | Why |
| --- | --- | --- |
| 1 Apple Foundation Models | **iPhone** (and Mac if the framework is available there) | The model is on the device and the phone has the photos first. Gate on `SystemLanguageModel.default.availability` |
| 2 Claude / ChatGPT | **Mac**, not the phone | The Mac has all photos and renders, a stable network and a place for the key. **No API key ever ships inside the iOS app.** The key lives in the Mac Keychain, entered by the user, or later behind a small hosted proxy |

To confirm in the spike *(verify)*:

- Foundation Models gained **image input in iOS 27** (WWDC26 session 241). One secondary source says image input may
  need a higher-capability model variant that only part of devices have; others say the base model does it. Test on
  the oldest target iPhone and Mac. If it is not universal, Tier 1 is "where available".
- The on-device model is small. Use it for coarse triage (A, simple B), not as the QA reviewer (C). C is where the
  cloud tier earns its cost.
- Apple Intelligence is region and language limited. Check Danish as well as English.

## 4. Privacy and consent (Denmark/EU: GDPR applies)

Photos of a table can show a home, a person, a screen, a GPS tag. Treat every cloud send as publishing.

Send the **least that works**, in levels the user picks per scan:

| Level | Sent | Typical risk |
| --- | --- | --- |
| 0 | Nothing leaves the device (Tier 0/1 only) | none |
| 1 | Numbers only: photo counts, sharpness stats, extents, depth coverage | negligible |
| 2 | Level 1 + **mesh renders** (object only, no background) | low |
| 3 | Level 2 + up to 6 to 8 representative **source photos** | real: backgrounds, faces |

For any image that is sent:

- Strip EXIF including GPS and device identifiers. Re-encode; never forward the original file.
- Downscale (long edge around 1500 px *(verify each provider's limits and cost curve)*). More pixels rarely help.
- Select, do not dump: a coverage-based pick of a few photos, not the whole set of 100+.
- Optional: blur faces with Vision; mask the background once we have an object mask.
- **The consent screen shows the actual thumbnails about to be sent**, the provider and the approximate cost. Off by default.
- Provider terms: prefer API tiers with no training on inputs and short or zero retention, and say which applies in
  settings. Objects from work or customers may be confidential, so level 0 is the default.
- Audit trail in the sidecar: provider, model, time, level, hashes of what was sent.
- If the user turns Apple Intelligence off, Tier 1 reports unavailable and we do not work around it.

## 5. Architecture and files

New Swift package `packages/scan-advisor` (pure logic, no UI), compiled by both apps like `scan-link`:

```
Sources/ScanAdvisor/
  ScanAdvice.swift          schema, Codable, versioned
  ScanAdvisor.swift         protocol, AdvisorID, errors
  AdviceValidator.swift     clamp to whitelist, enforce minimum photo count, reject bad output
  ImagePreparer.swift       strip EXIF, downscale, re-encode, hash
  PhotoSelector.swift       coverage-based pick of N photos from camera poses
  Consent.swift             levels, what each may contain, cost estimate
  Prompts.swift             versioned prompt templates
Sources/ScanAdvisorProviders/
  FoundationModelsAdvisor.swift   #if canImport(FoundationModels)
  AnthropicAdvisor.swift          Messages API, image blocks, JSON-schema output
  OpenAIAdvisor.swift             Responses API, image input, JSON-schema output
Tests/  FakeAdvisor, validator, preparer (EXIF really gone), selector, consent
```

Integration points in existing code:

| Where | Change |
| --- | --- |
| `apps/3lay-mac/PhotoReconstruction.swift` | After `PhotoQuality.filter` run triage (A, B) and apply whitelisted settings; after import run QA (C) |
| `apps/3lay-mac/ReconstructionReport.swift` | Add `advisorId`, `advisorModel`, `consentLevel`, `adviceApplied`, `defectCount` so runs stay comparable |
| `apps/3lay-mac/ThreeLayMacOS.swift` | Settings: provider, key (Keychain), consent level, monthly cost cap. Result view lists defects and "rescan these angles" |
| `apps/3lay-ios/Sources/CaptureApp/ReviewView.swift` | Tier 1 "capture check" before sending: glare, clutter, too few angles |
| `packages/scan-link/.../LanProtocol.swift` | Only if the phone should pass its Tier 1 advice to the Mac: optional `advice.json` in the upload, a new `/api/hello` capability flag, old Macs keep working, update `docs/LAN_LINK.md` in the same commit |
| `docs/LIDAR_BUNDLE.md` | No change. Advice is a sidecar, not part of the bundle |

The Mac app needs outbound network: check `apps/3lay-mac/project.yml` and `build.sh` for sandbox entitlements
(`com.apple.security.network.client`) before the first cloud call. Add timeouts, one retry, and a hard per-scan and
per-month cost cap. A failed or slow advisor must never block a scan; the result is then Tier 0.

## 6. Phases

**Phase 0 - spike and decision gate (about a week).** No product code.
- Verify the *(verify)* items against primary docs.
- Offline script on the fixture objects from `docs/RECONSTRUCTION_BASELINE.md`: send the same inputs to Foundation
  Models, Claude and ChatGPT and collect `ScanAdvice` JSON.
- Gate: does any advisor flag seeded problems (deliberately blurry, glossy, cluttered, holey scans) more reliably than
  a naive baseline? If not, stop and spend the effort on depth fusion instead.

**Phase 1 - contract.** `scan-advisor` package: schema, validator, preparer (with an EXIF test), selector, consent,
fake advisor. Fully tested without network.

**Phase 2 - Mac cloud advisor (A and C first).** Anthropic and OpenAI providers, Keychain key, consent UI, sidecar,
report fields. Off by default.

**Phase 3 - on-device advisor.** Foundation Models provider, availability gating, capture check on the phone.

**Phase 4 - evaluation and decision.** Run section 7, record the numbers in `docs/RECONSTRUCTION_BASELINE.md`, keep,
tune or remove each role by its result.

**Phase 5 - research, only if 0 to 4 pay off.** Role E (primitive snapping), per-pass object segmentation.

## 7. How we know it helped

Reuse the existing protocol: fixtures with independently measured dimensions, three runs each, `DimensionalError`.
Compare **baseline settings** with **advised settings** per fixture.

| Metric | Source | Keep the role if |
| --- | --- | --- |
| Dimensional error (mm, %) | `DimensionalError.compare` | Median error drops on the hard fixtures (reflective, low-texture) and does not rise on easy ones |
| Repeatability | `DimensionalError.repeatability` | Not worse. An advisor that adds run-to-run variance is a loss even if the mean improves |
| Defect detection | Seeded flaws with known locations | Precision and recall both clear a bar set in Phase 0 (suggest 0.7 each) |
| Scale mismatch alarms | Fixtures with a printed label | No false alarms that would annoy; we never override anyway |
| Cost and time | Report sidecar | Under the per-scan cap; no scan blocked |

Test each provider alone, since they will differ, and repeat identical input to see how stable the advice is.

## 8. Risks

| Risk | Mitigation |
| --- | --- |
| Model hallucinates a defect or setting | Whitelist, validator, advisory by default, the user sees the view the claim refers to |
| Advice makes results worse | Phase 4 A/B; each role switches off on its own |
| Private content leaves the device | Levels, EXIF strip, thumbnails on the consent screen, off by default |
| API key leaks | Never in the iOS app or the repo; Mac Keychain; later a proxy |
| Provider or model changes silently | Model id and prompt version in every sidecar; pin versions; rerun the eval on change |
| Cost surprises | Image caps, per-scan and monthly caps, estimate shown before sending |
| On-device model missing on some devices or in Danish | Availability gating; the tier is optional |
| Effort better spent elsewhere | Phase 0 gate; depth fusion and masking continue in parallel |

## 9. Decisions needed

1. **Minimum OS:** is iOS 27 / macOS 27 acceptable as the floor for Tier 1, or must it degrade on older systems?
2. **Keys:** a user-supplied API key stored on the Mac (simplest), or a hosted proxy (needed if the phone should call a cloud model)?
3. **Data:** are scanned objects ever confidential? That decides whether level 3 is offered at all.
4. **Providers:** Claude and ChatGPT from the start, or one first and the second only if Phase 0 justifies it?
5. **Budget:** a per-scan and monthly cost ceiling for the cloud tier.
