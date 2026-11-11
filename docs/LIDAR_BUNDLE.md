# LiDAR scan bundle (`3lay-lidar/2`)

A LiDAR scan is a folder the phone zips as `<name>.lidar.zip`. The Mac imports the mesh and keeps the rest
next to it. Version 2 only adds fields to version 1: a reader that knows version 1 still reads everything it
knew, and the Mac accepts any `3lay-lidar/` format, so an older Mac imports a v2 bundle and ignores the depth.
The Swift types are `LidarManifest`, `LidarGeometry` and `LidarBundleValidator` in `apps/3lay-ios/Sources/CaptureKit`;
the numbers below are checked by tests there, not only described.

```
manifest.json
mesh/scan.ply          binary little-endian PLY, meters, Z up
photos/NNNN.jpg        sRGB JPEG, raw sensor orientation (not rotated to portrait)
depth/NNNN.depth       v2: Float32 little-endian, meters, row-major, depth.width x depth.height
depth/NNNN.conf        v2: UInt8 per pixel, 0 = low, 1 = medium, 2 = high confidence
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

## Other per-photo fields (v2)

`trackingState` ("normal" is all that is captured today) and `exposure` (`duration` s, `offset` EV, `ambientIntensity`).

## Validation

`LidarBundleValidator.validate` reports, with the photo it concerns: missing files, wrong depth/confidence sizes,
non-rigid transforms, non-finite or non-positive intrinsics, a principal point outside the image, depth/photo
aspect mismatch, paths that leave the bundle, and depth without the `depth/1` capability. The phone drops depth
that fails validation from a photo (the photo itself is kept) and refuses to save a bundle with other problems.

## Not in this format yet

High-resolution stills (`ARFrame.captureHighResolutionFrame`), per-pass object segmentation for multi-pass object
capture, and a Mac-side depth-fusion reader. The Mac does not use the depth yet.
