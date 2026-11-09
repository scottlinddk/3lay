# 3lay iOS

3lay iOS, the native capture app (#25): guided Object Capture, then either send the raw photos to your Mac
for full-detail reconstruction (recommended) or reconstruct on the phone.

- `Sources/CaptureKit`: pure logic, unit-tested with `swift test` on a Mac: `capture-bundle/1`
  manifest and writer, API client, resumable chunked upload, submission, pairing link.
- `Sources/CaptureApp`: SwiftUI and RealityKit `ObjectCaptureSession` UI. iOS only.
- `App/` + `project.yml`: app shell for XcodeGen (see Build).

## Pairing

The web app (or you, with `POST /api/tokens {"kind": "device"}`) produces a link
`scan3d://pair?server=https://<host>&token=<device token>`. Opening it on the phone stores the
server and token in the Keychain. Plain `http` is accepted only for `localhost`.

## Nearby Mac (no server)

**Find a Mac nearby** discovers 3lay Mac (`apps/3lay-mac`) over Bonjour on the same Wi-Fi,
pairs with the six-digit code the Mac shows, then **Send to <Mac>** reconstructs on the phone and
sends the USDZ straight to it. The shared contract is `packages/scan-link`, explained in
`docs/LAN_LINK.md`. Plain HTTP, local network only. The server device token is not used here.

## Flow (server mode)

1. Capture with `ObjectCaptureSession` (needs LiDAR; checked at runtime, not by model name).
2. **Send to Mac:** photos plus `manifest.json` upload as `photo` and `capture_bundle` artifacts,
   then a `reconstruct` task is queued for the Mac worker (#23). Uploads resume after a lost
   connection or relaunch.
3. **On phone:** `PhotogrammetrySession` (`.reduced`) writes a USDZ, uploaded as an `original`.
   Ingest of USDZ (#9) is not implemented yet.

## Build and test

```sh
swift test                                   # CaptureKit unit tests (macOS); also builds packages/scan-link
xcodebuild -scheme CaptureApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

`ObjectCaptureSession` is not in the simulator SDK, so build for the device SDK. For an installable
app: `brew install xcodegen && xcodegen generate`, open `ThreeLayIOS.xcodeproj`, set your team.

## Manual device checks (cannot be automated)

- [ ] Nearby Mac checks in `docs/LAN_LINK.md` (Local Network prompt, pairing, real scan arrives).
- [ ] LiDAR iPhone/iPad on a current iOS: capture a real object end to end, note iOS version and model.
- [ ] Unsupported (non-LiDAR) device shows the explanation instead of crashing.
- [ ] Open a pairing link: a confirmation names the server host, nothing is stored until you accept, and a second link asks before replacing the current server. Server and token persist across relaunch; Unpair clears them.
- [ ] Airplane mode mid-upload, then reconnect and relaunch: the upload resumes, no duplicates.
- [ ] 30+ photo set uploads fully and the Mac worker reconstructs it.
- [ ] On-device reconstruction finishes on the target device without being killed for memory.
- [ ] Measure the result against the object: sensor scale is provenance, not a guarantee.

## CI and TestFlight (#34)

- `.github/workflows/ios.yml` (macOS runner, on changes under `apps/3lay-ios` or the Mac CLI):
  `swift test` for CaptureKit, a device-SDK compile of `CaptureApp`, and test + release build of the
  Mac `scan3d-object-capture` CLI.
- `.github/workflows/testflight.yml` is manual (`workflow_dispatch`, `testflight` environment).
  It generates the project with XcodeGen, archives with automatic signing through an App Store
  Connect API key, and uploads via `ExportOptions.plist` (`destination: upload`). The build number is
  the run number.
  - Secrets: `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
    `APP_STORE_CONNECT_KEY_P8_BASE64` (`base64 -i AuthKey_XXXX.p8`). Variable: `APPLE_TEAM_ID`.
  - Create the app record (bundle id `app.scan3d.capture`) in App Store Connect first.
  - Neither workflow has run yet. Treat the first run as the verification and expect fixes.
