# 3lay

Turn real-world objects into your next 3D printing project. 3lay pairs guided iPhone scanning with a Mac companion app, letting you capture an object, send it over local Wi-Fi, inspect it on the big screen, and export an STL for your printing workflow. From something you can hold to something you can create with.

| Path | What it is |
| --- | --- |
| `apps/3lay-ios` | 3lay iOS: capture app (SwiftUI, Object Capture). From [3D-scan](https://github.com/scottlinddk/3D-scan). |
| `apps/3lay-mac` | 3lay Mac: receives scans, previews them and exports STL. From [scanbench](https://github.com/scottlinddk/scanbench). |
| `packages/scan-link` | The LAN contract both apps compile: Bonjour service type, routes, client, address rules. |
| `docs/LAN_LINK.md` | How the two apps find and talk to each other, security model, manual checks. |

## Connecting the apps

On the same Wi-Fi network: open 3lay Mac on the Mac, open 3lay iOS, choose **Find a Mac
nearby**, pick the Mac and type the code 3lay Mac shows. After a capture choose **Send to <Mac>**.
Details and limits (plain HTTP, local network only) are in [docs/LAN_LINK.md](docs/LAN_LINK.md).

## Build

Needs macOS with Xcode.

```sh
swift test --package-path packages/scan-link
swift test --package-path apps/3lay-ios
(cd apps/3lay-mac && ./rebuild_check)   # builds build/Scanbench.app and runs the loopback check
```

3lay iOS additionally needs XcodeGen and a device with LiDAR, see `apps/3lay-ios/README.md`.

## Not included from the source repositories

- The 3D-scan web app, API and pipeline. 3lay iOS's optional **server** mode still talks to that
  API (`scan3d://pair` links) but the server is not part of this repository.
- Scanbench's committed `build/` output and `legacy-rust/` prototype.
