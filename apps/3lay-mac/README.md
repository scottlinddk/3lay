# 3lay Mac

A Swift desktop prototype for bringing phone scans onto a print plate. It accepts STL, OBJ, and ASCII PLY surface meshes through drag-and-drop, a file chooser, or a local Wi-Fi upload page. It can also read the companion iOS app's HTTPS server using the same pairing link and download its reconstructed USDZ. It shows a mesh preview, source dimensions, an explicit scale control, simple rotation, and binary STL and 3MF export. 3MF states its unit (millimetres), so Bambu Studio opens it at the right size; it holds geometry only, with no printer, filament or toolpaths.

## Run

On macOS, run `./build.sh` from this directory, then open `build/ThreeLayMacOS.app` (shown as 3lay Mac). Run `./rebuild_check` to rebuild and check mesh import and export. The build uses the Swift compiler included with Xcode and needs no downloaded packages.

To edit and run in Xcode, run `../../scripts/open-xcode.sh` and run the `ThreeLayMacOS` scheme in `3lay.xcworkspace`. It uses `project.yml`, so the app gets its Info.plist (Bonjour, local network) and bundled `convert_usdz.swift`. `build.sh` remains the CI/release build; keep the plist keys in both in sync.

## Companion app import

Paste the `scan3d://pair` link from the companion web app into **Companion app**, choose **Find phone scans**, then import a listed scan. The app lists jobs and artifacts on the paired HTTPS server with the link's device token. A reconstructed USDZ is converted locally to STL with macOS ModelIO or a `usdcat` fallback. The fallback passed a synthetic tetrahedron check; a real phone capture still needs a device test. The link stays in memory while the app is open.

## iOS app handoff (Nearby Mac)

3lay Mac advertises itself on Bonjour as `_threelaymacos._tcp`. In 3lay iOS choose **Find a Mac nearby**, pick this Mac and enter the six-digit code from **Import a scan**. **Send to <Mac>** then delivers a USDZ, which is converted to STL and opened. The code is kept between launches; **New code** revokes paired phones. See `../../docs/LAN_LINK.md` for the contract and security model. `./rebuild_check` runs a loopback test of this path.

## Phone browser handoff

The desktop window shows a local address and six-digit pairing code. On a phone connected to the same Wi-Fi network, open that address, enter the code, choose an STL, OBJ, or ASCII PLY file, and tap **Send to desktop**. Another uploader can use `PUT /upload/<URL-encoded filename>?code=<six-digit code>` with the raw file bytes and a `Content-Length` header. Uploads are capped at 100 MB (STL, OBJ, ASCII PLY or USDZ) and saved in `~/Library/Application Support/ThreeLayMacOS/inbox/`. The HTTP endpoint is local-network only in intent but binds to all interfaces; use it only on a trusted network.

## Current limits

This prototype does not read 3MF, GLB or binary PLY, repair geometry, validate printability, create printer profiles, slice, or export a printer project. The plate dimensions are a visual guide only. A future version should implement the companion repository's authenticated resumable upload contract and full preparation pipeline.
