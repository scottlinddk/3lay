# 3lay

Scan an object with your phone, check it on your Mac, and get it onto a print plate.

| Path | What it is |
| --- | --- |
| `apps/capture-ios` | iOS capture app (SwiftUI, Object Capture). From [3D-scan](https://github.com/scottlinddk/3D-scan). |
| `apps/scanbench-mac` | Mac app that receives scans, previews them and exports STL. From [scanbench](https://github.com/scottlinddk/scanbench). |
| `packages/scan-link` | The LAN contract both apps compile: Bonjour service type, routes, client, address rules. |
| `docs/LAN_LINK.md` | How the two apps find and talk to each other, security model, manual checks. |

## Connecting the apps

On the same Wi-Fi network: open Scanbench on the Mac, open the iOS app, choose **Find a Mac
nearby**, pick the Mac and type the code Scanbench shows. After a capture choose **Send to <Mac>**.
Details and limits (plain HTTP, local network only) are in [docs/LAN_LINK.md](docs/LAN_LINK.md).

## Build

Needs macOS with Xcode.

```sh
swift test --package-path packages/scan-link
swift test --package-path apps/capture-ios
(cd apps/scanbench-mac && ./rebuild_check)   # builds build/Scanbench.app and runs the loopback check
```

The iOS app additionally needs XcodeGen and a device with LiDAR, see `apps/capture-ios/README.md`.

## Not included from the source repositories

- The 3D-scan web app, API and pipeline. The iOS app's optional **server** mode still talks to that
  API (`scan3d://pair` links) but the server is not part of this repository.
- Scanbench's committed `build/` output and `legacy-rust/` prototype.
