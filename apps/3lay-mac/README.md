# 3lay Mac

A Swift desktop prototype for bringing phone scans onto a print plate. It accepts STL, OBJ, and ASCII PLY surface meshes through drag-and-drop, a file chooser, or a local Wi-Fi upload page. It can also read the companion iOS app's HTTPS server using the same pairing link and download its reconstructed USDZ. It shows a mesh preview, source dimensions, an explicit scale control, simple rotation, and binary STL export.

## Run

On macOS, run `./build.sh` from this directory, then open `build/ThreeLayMacOS.app` (shown as 3lay Mac). Run `./rebuild_check` to rebuild and check mesh import and export. The build uses the Swift compiler included with Xcode and needs no downloaded packages.

To edit and run in Xcode, run `../../scripts/open-xcode.sh` and run the `ThreeLayMacOS` scheme in `3lay.xcworkspace`. It uses `project.yml`, so the app gets its Info.plist (Bonjour, local network) and bundled `convert_usdz.swift`. `build.sh` remains the CI/release build; keep the plist keys in both in sync.

## Companion app import

Paste the `scan3d://pair` link from the companion web app into **Companion app**, choose **Find phone scans**, then import a listed scan. The app lists jobs and artifacts on the paired HTTPS server with the link's device token. A reconstructed USDZ is converted locally to STL with macOS ModelIO or a `usdcat` fallback. The fallback passed a synthetic tetrahedron check; a real phone capture still needs a device test. The link stays in memory while the app is open.

## iOS app handoff (Nearby Mac)

3lay Mac advertises itself on Bonjour as `_threelaymacos._tcp`. In 3lay iOS choose **Find a Mac nearby**, pick this Mac and enter the six-digit code from **Import a scan**. **Send to <Mac>** then delivers a USDZ, which is converted to STL and opened. The code is kept between launches; **New code** revokes paired phones. See `../../docs/LAN_LINK.md` for the contract and security model. `./rebuild_check` runs a loopback test of this path.

## Two capture modes from the phone

3lay Mac imports both kinds of scan the phone can send:

| Phone mode | Best for | What arrives | What the Mac does |
| --- | --- | --- | --- |
| **Scan an object** (Object Capture) | Small objects: books, parts, figurines | `.zip` of photos with embedded LiDAR depth | Builds the model itself with Object Capture (below) |
| **Scan a room or large object (LiDAR)** | Rooms, furniture, big objects | `*.lidar.zip`: ARKit LiDAR mesh (binary PLY, meters, Z up) + posed photos + `manifest.json` | Imports the LiDAR mesh as is (metres to millimetres) and keeps the photos and their camera poses in the inbox |

LiDAR meshes are around 1 cm coarse, so small objects come out better from photogrammetry. The photos in a LiDAR bundle are not used for geometry or colour on the Mac yet; they are kept with exact poses for that next step. The browser upload page and **Import file** also take binary little-endian PLY now.

## Photo scans from the phone

When the phone sends photos, 3lay Mac checks them before Object Capture builds the model. It sets aside photos that are much softer than the ones taken just before and after them (at most a quarter of the photos, never below 20) and counts how many photos carry LiDAR depth, which Object Capture uses for scale and for surfaces with little texture. Photos are compared with their neighbours, not with the whole capture, so views of a plain side of the object are kept. The status line reports the result, for example `1M-triangle detail · 118 photos (2 blurry set aside) · LiDAR depth in 120 of 120`.

Detail for printing has to be in the shape, because an STL has no texture. Apple's preset levels stop at 250,000 triangles (Full) and keep finer detail in texture maps, so the model is built at a custom level with up to 1 million triangles, with high feature sensitivity. **Maximum detail** in *Import a scan* raises that to 3 million. A level that fails falls back to Full, then Medium. This needs macOS 14, which is the oldest macOS 3lay Mac runs on.

Object Capture models stand along Y. USDZ scans are turned on import to stand along Z, on the plate.

## Clean rebuild (optional, AI)

A second path beside the scan, for mechanical parts. Under **Clean rebuild** save an Anthropic API key (kept in the login keychain), say what the object is, and choose **Rebuild as a clean part**. On the phone the same thing is the **Also rebuild as a clean part (AI)** switch on the *Capture complete* screen; it is only accepted when the Mac has a key.

How it works (`PartRebuild.swift`):

1. The Mac draws the scan from the top, front, right and one corner, without perspective (`MeshRender.swift`), and sends those pictures, the measurements and your description to Claude (`claude-opus-5-5`). Photos are not sent.
2. Claude answers with a tree of simple solids as JSON: box, cylinder, cone, sphere, torus, extruded outline, combined with union, subtract and intersect (`SolidShape.swift`).
3. The Mac builds that shape, measures it against the scan in both directions (`ShapeFit` in `SolidMesher.swift`) and sends the numbers, the worst places and pictures of the attempt back. Up to three rounds; the closest attempt wins.
4. The result is a closed mesh in the scan's position. **Scan / Clean part** switches what is on the plate and what **Export placed STL** saves. **Save as OpenSCAD…** writes the same shape as editable source.

What to expect: flat faces, right angles and round holes come out exact where the scan was bumpy, and the mesh is always closed. It is not more accurate than the scan it measures from: a scale error in the scan stays. Sharp edges are rounded by about the mesh grid (the longest side divided by 224); the OpenSCAD file has them sharp. Organic shapes do not fit simple solids, and the reported deviation says so. It costs API usage on your account for each round.

`RebuildCheck.swift` covers everything except the call to Claude, which has not been run from this repository yet.

## Phone browser handoff

The desktop window shows a local address and six-digit pairing code. On a phone connected to the same Wi-Fi network, open that address, enter the code, choose an STL, OBJ, or ASCII PLY file, and tap **Send to desktop**. Another uploader can use `PUT /upload/<URL-encoded filename>?code=<six-digit code>` with the raw file bytes and a `Content-Length` header. Uploads are capped at 100 MB (STL, OBJ, ASCII PLY or USDZ) and saved in `~/Library/Application Support/ThreeLayMacOS/inbox/`. The HTTP endpoint is local-network only in intent but binds to all interfaces; use it only on a trusted network.

## Current limits

This prototype does not parse 3MF, GLB or binary PLY, repair geometry, validate printability, create printer profiles, slice, or export a printer project. The plate dimensions are a visual guide only. A future version should implement the companion repository's authenticated resumable upload contract and full preparation pipeline.
