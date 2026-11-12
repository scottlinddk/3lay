# On-device Scan Coach

Scan Coach helps people capture better inputs. It does not repair geometry, synthesize missing surfaces,
change capture thresholds, delete photos, or guarantee dimensional accuracy.

## Availability and rollout

- The app still targets iOS 17. Measured reports work on every supported capture device.
- Text prioritization uses Foundation Models on iOS 26+, checks `SystemLanguageModel.availability`
  and locale support, and always selects `SystemLanguageModel.default` explicitly.
- Image assessment uses iOS 27 `Attachment(imageURL:)` and checks `.capabilities.contains(.vision)`.
  This code is compiled with Swift 6.4+ (Xcode 27 SDK); older builds omit image assessment.
- Settings → Scan assistance has two switches, both off by default. This is an experimental opt-in
  rollout until physical-device evaluation demonstrates benefit. No cloud model or network tool is used.
- Model download, device eligibility, Apple Intelligence settings, language support, refusal, timeout,
  and resource pressure can prevent inference. Measured guidance remains usable.

## Data and behavior

`ScanQualityAccumulator` observes the existing LiDAR policy's decisions without affecting them. Its
counters record the first rejection reason per evaluated frame, not independent defect probabilities.
Coverage always describes **observed** surfaces; unseen areas and overall completeness remain unknown.
Small sample sets do not generate rate-based defect warnings. Object Capture reports only the session
feedback and pass information it exposes; it does not invent LiDAR measurements.

`ScanQualitySnapshot` is saved in `scan-quality.json` beside the manifest, outside source-photo folders.
Old scans get a count-only snapshot. `ScanQualityReport` validates every generated action/evidence pair,
rejects duplicates and invented evidence, and never lets the model suppress thermal guidance. Displayed
instructions and explanations use controlled text derived from measured evidence, rather than unverified
free-form model prose. The model's role is prioritization.

Optional visual assessment samples the first, middle, and last image in capture filename order (at most
three), using a fresh session per image. It classifies possible glare, difficult surfaces, framing, or
background distraction; uncertain results yield no finding. These observations are labeled as AI and
reference their source photo. They do not become measured facts or modify capture behavior. No file,
network, or mutation tools are exposed to the model, and text within images is treated as data.

`scan-advice.json` stores the report, visual observations, prompt version, OS version, elapsed inference
time, and resident memory samples. These small sidecars follow the scan's deletion/retention lifecycle.
A LiDAR bundle sent by the user can include these sidecars; analysis itself is entirely on-device.
No copy of the source photos or transcript is retained by Scan Coach.

Live coaching runs at completed object passes and LiDAR coverage plateaus, with a 20-second minimum
interval. Current camera warnings take precedence. Stale evidence is not displayed. Requests cancel on
view exit, backgrounding, disabling the feature, or thermal pressure. Only one inference runs globally.
The UI falls back after 12 seconds (25 with photos), even if provider cancellation takes longer. The
runner retains its slot until provider exit. Reconstruction cancels inference and waits for that exit
before starting; it blocks further inference until reconstruction ends.

## Automated verification

Run from `apps/3lay-ios`:

```sh
swift test
xcodebuild -scheme CaptureApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Tests cover sparse/healthy scans, unknown measurements, coverage semantics, rejection aggregation,
invalid/contradictory/duplicate model choices, heat precedence, bounded image selection, sidecar integrity,
timeout recovery, provider failure, cancellation, concurrent requests, and reconstruction exclusion.
`Tests/CaptureKitTests/Fixtures/scan-coach-cases.json` is a repeatable evaluation set for measured fallback.
These tests do not run Apple's model or prove improved geometry.

## Physical-device evaluation

Use the same object, lighting, phone, reconstruction settings, and measured reference dimensions per
pair. Randomize which condition runs first. Start each trial at nominal thermal state. Test textured,
reflective, transparent, low-texture, thin, and partially occluded objects, plus a room. Include low-light
and fast-motion trials. Run at least five paired trials per category.

Compare coach-off versus coach-on text advice first; compare image assessment separately. Keep original
photos and reconstruction outputs for blinded quality review. Record a JSON array with one entry per trial:

```json
[
  {
    "pair": "textured-01", "condition": "baseline", "success": true,
    "captureSeconds": 140, "dimensionErrorMM": 2.1, "holes": 2,
    "peakMemoryMB": 820, "seriousThermal": false,
    "adviceCount": 0, "unsupportedAdviceCount": 0, "inferenceMilliseconds": 0
  },
  {
    "pair": "textured-01", "condition": "coach", "success": true,
    "captureSeconds": 135, "dimensionErrorMM": 1.8, "holes": 1,
    "peakMemoryMB": 930, "seriousThermal": false,
    "adviceCount": 3, "unsupportedAdviceCount": 0, "inferenceMilliseconds": 2200
  }
]
```

These numbers are format examples, not measured results. Use `null` for dimension error when
reconstruction fails; always record success separately. Use Instruments for actual peak memory,
energy, and dropped frames. Sidecar memory values are before/after samples, not peak memory.
`coach.text` and `coach.vision` signposts identify inference. Run:

```sh
python3 scripts/evaluate-scan-coach.py trials.json
```

Suggested release gates (targets, not achieved results):

- Zero unsupported measured claims, stale advice, changed originals, or overlapping inference/reconstruction.
- No reduction in paired reconstruction success or increase in median dimensional error/hole count.
- At least 10% improvement in one primary quality metric or capture time, without worse quality.
- No increase in serious thermal events; inspect memory/energy and frame-drop regressions with Instruments.
- 95th-percentile text latency under 5 seconds and visual latency under 20 seconds on the oldest supported device.

Also exercise Apple Intelligence off/model unavailable, unsupported locale, offline mode, empty/corrupt
photos, app backgrounding, cancel mid-inference, scan deletion, immediate reconstruction, and largest
Dynamic Type/VoiceOver. Actual model quality, latency, energy, and camera interaction require a supported
physical device. Keep the feature opt-in until these checks are recorded.

## References

- https://developer.apple.com/documentation/foundationmodels
- https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting
- The Xcode 27.2 iPhoneOS FoundationModels Swift interface supplies the availability guards used here.
