# LiDAR scan bundle (`3lay-lidar/3`)

A LiDAR scan is a folder the phone zips as `<name>.lidar.zip`. The Mac imports the mesh and keeps the rest
next to it. Version 2 only adds fields to version 1: a reader that knows version 1 still reads everything it
knew, and the Mac accepts any `3lay-lidar/` format, so an older Mac imports a v2 or v3 bundle and ignores what it
does not know. Version 3 again only adds fields: depth keyframes, a RoomPlan layout and a flag for full-resolution
stills. The format and the `capabilities` list follow what the bundle really contains: a scan with none of the
extras is still written as version 1 or 2.
The Swift types are `LidarManifest`, `LidarGeometry` and `LidarBundleValidator` in `apps/3lay-ios/Sources/CaptureKit`;
the numbers below are checked by tests there, not only described.

```
manifest.json
mesh/scan.ply          binary little-endian PLY, meters, Z up
photos/NNNN.jpg        sRGB JPEG, raw sensor orientation (not rotated to portrait)
depth/NNNN.depth       v2: Float32 little-endian, meters, row-major, depth.width x depth.height
depth/NNNN.conf        v2: UInt8 per pixel, 0 = low, 1 = medium, 2 = high confidence
depth/fNNNNN.depth     v3: depth keyframe, Float16 little-endian meters (or Float32, see `encoding`), own pose
depth/fNNNNN.conf      v3: UInt8 confidence for the keyframe
room/room.json         v3: RoomPlan `CapturedRoom` (walls, doors, windows, furniture boxes), rooms and large objects only
room/room-data.json    v3: RoomPlan's raw `CapturedRoomData`, so the layout can be rebuilt later
room/room.usdz         v3: the same layout for Quick Look
```

`manifest.json` is written last. A folder with a manifest is a complete scan.

## Coordinate conventions

| Thing | Convention |
| --- | --- |
| Units | meters everywhere (`units: "meters"`) |
| World (photo `transform`) | ARKit world: right-handed, **+Y up**. `transform` is camera-to-world, 16 floats, column-major |
| Camera | +X right, +Y up, looks along **-Z** |
| Image / depth pixels | u to the right, v **down**, origin at the top-left corner, continuous coordinates |
| Mesh file | **Z up**: world (x, y, z) becomes (x, -z, y). A rotation, so triangle winding is kept. `meshFromWorld` in the manifest is this matrix |
| Intrinsics | `[fx, fy, cx, cy]` in pixels of the stored image |

Projecting a world point into a photo: `c = inverse(transform) * p`, `depth = -c.z`, `u = fx * c.x / depth + cx`,
`v = cy - fy * c.y / depth`. `LidarGeometry.project` and `unproject` do exactly this.

Resizing an image by `sx`, `sy` scales `fx, cx` by `sx` and `fy, cy` by `sy`. `depth.intrinsics` is the photo's
intrinsics scaled to the depth map's size.

## Depth

Each photo may have one depth observation from the **same ARKit frame**. It covers the photo's field of view at
lower resolution (256 x 192 for a 1920 x 1440 photo), so the aspect ratios must match.

- `timeOffset` is the seconds the depth lies after the photo's pixels. It is 0 today because both come from one
  frame. A future high-resolution still would have a non-zero offset, and then the depth is *not* exact ground
  truth for that photo: use the recorded poses to account for the motion in between.
- `smoothed` says ARKit's temporally smoothed depth was used instead of the raw per-frame depth.
- Depth is a noisy measurement. Use the confidence map, and prefer photo reconstruction for fine detail;
  LiDAR depth is for scale, alignment, coarse shape and consistency checks.

## Depth keyframes (v3)

`depthFrames` lists depth observations that are **not tied to a photo**. The phone keeps one up to five times a second
while it moves (not while it is held still, slower when warm, at most 1,200), so a scan has far more depth than photos.
Each has its own `transform` (camera to world, same convention as a photo), `intrinsics` for its own depth map, a
`timestamp`, an `encoding` (`float16` or `float32`, little-endian meters along the optical axis) and a confidence file.
Float16 halves the size and its rounding (about 1 mm at 1 m, 2 mm at 3 m) is below LiDAR noise.

The Mac uses a sample of them to check that the depth and the mesh agree (`LidarSidecars.DepthAgreement`): depth pixels
with high confidence are placed in the mesh frame and compared with the nearest mesh vertex. The median has a floor of
about half the vertex spacing, so it detects drift or a wrong scale, not small errors.

## Full-resolution stills (v3)

A photo with `highRes: true` is a still from `ARSession.captureHighResolutionFrame`, scaled to at most 3,024 px on its long
edge, replacing the video frame that was saved first. It is requested rarely (at most every 3 s, only on a cool phone) and
kept only if it shows the same view (within 0.2 m and about 12 degrees), is larger, and was not exposed longer than the
video frame. Its `transform`, `intrinsics`, `width`, `height` and `exposure` are the still's. Its `timestamp` stays the
video frame's, which keeps photos in time order. The original video depth is moved to `depthFrames` as a Float32
observation with its original pose, intrinsics and timestamp; the still has no per-photo `depth`. This avoids applying
the still's changed camera pose to depth captured earlier.

## Room layout (v3)

`room` points at Apple's RoomPlan output for the same capture session, in the same ARKit world as the photos. It gives
walls, doors, windows, openings and furniture as boxes with real dimensions: a skeleton to check the mesh against. RoomPlan
recognises room-defining things, not small objects, so it is only recorded for room scans. `room.json` is RoomPlan's
`CapturedRoom` encoded as JSON (its own schema, versioned by Apple); the manifest carries the counts. A layout that fails to build
is left out and the scan is still saved.

## Coverage while scanning

The phone colors its live mesh red (needs photos), orange (almost) or green (covered), and shows a "photo detail" figure:
the share of the surface LiDAR has seen that photos show well. `CoverageMap` scores each surface cell by the photos taken
so far: close enough (target 4 px per centimeter), not at a grazing angle, sharp, and not hidden behind something
(checked against that photo's own depth). A photo is saved only when it would add at least 0.06 m² of newly covered
surface, and a hint says when the figure has stopped improving (at least 65% covered, over two minutes in, no progress for
45 s). This figure is not the share of the room scanned. The method follows the idea in Wes Bos's
[3D Model Anything](https://github.com/wesbos/3d-model-anything) (MIT) and was written from scratch for these types.

## Other per-photo fields (v2)

`trackingState` ("normal" is all that is captured today) and `exposure` (`duration` s, `offset` EV, `ambientIntensity`).

## Validation

`LidarBundleValidator.validate` reports, with the photo it concerns: missing files, wrong depth/confidence sizes,
non-rigid transforms, non-finite or non-positive intrinsics, a principal point outside the image, depth/photo
aspect mismatch, paths that leave the bundle, and depth without the `depth/1` capability. The phone drops depth
that fails validation from a photo (the photo itself is kept) and refuses to save a bundle with other problems.

## Not in this format yet

Per-pass object segmentation for multi-pass object capture, a 640x480 color image beside each depth keyframe, and
Mac-side depth fusion. The Mac only uses the depth for the agreement check above.
