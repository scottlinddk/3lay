# Plan: ideas from Wes Bos's "3D Model Anything", RoomPlan, and small objects

Status: **proposal, nothing implemented.** Written 2026-11-12. Companion to `AI_ASSIST_PLAN.md`.

Sources: the video transcript supplied by the user, a screenshot of his app, and his repository
[wesbos/3d-model-anything](https://github.com/wesbos/3d-model-anything) (MIT, read at commit `31b2dc9`, 2026-10-22; app in
`apps/house-capture`). Section 2 and the "Findings from his code" section come from that code. Nothing here has been run.

## 1. What he does

1. LiDAR scene mesh while walking.
2. Hundreds of **high-resolution photos**, each saved with its camera pose, intrinsics, exposure, depth map and
   confidence map (`frames.json`). His complaint about Polycam: its photos are "blurry and tiny".
3. Apple **RoomPlan** for a coarse, dimensionally sound layout: walls, doors, windows, furniture as boxes.
4. Live feedback: mesh coloured **red where photos are missing, green where covered**; a "Photo detail 79%" gauge; a hint
   "Photo detail isn't improving much, you can save"; "Reducing background capture to keep the app responsive".
5. A zip, then an LLM skill (`scan-to-threejs`) builds the scene and loops: render from a photo's camera pose, compare
   with the photo, fix, repeat. It must label parts measured / modeled / estimated.

## 2. How many mesh points?

From his own `demos/office-v4/BRIEF.md`: **501,651 mesh faces (triangles), 165 photos, 1,112 depth frames**, and a
wall-plane RMS of **2.6 cm**. The repo ships no vertex count and no raw mesh (only derived measurements), so "points"
cannot be counted; triangles is the figure to compare. About half a million triangles is what ARKit's scene mesh gives for a room, the
same hardware we use, so the mesh is not his advantage. Our app already shows `triangleCount` while scanning; scan the
same room with both apps to compare. 2.6 cm is good for furniture and not for a print or a construction drawing.

## 2b. Findings from his code

| Topic | What `HouseCapture` does | Where |
| --- | --- | --- |
| One session for everything | `RoomCaptureSession(arSession:)` shares one ARSession with mesh (`.meshWithClassification`), `.sceneDepth` and photo capture. Confirms the iOS 17 shared-session route | `CaptureController.swift:117,368` |
| Coverage score | Per mesh vertex: projects it into each photo; needs angle `cosθ > 0.2`, checks **occlusion against that photo's depth**, and scores `min(1, px/cm / 4) * sharpness`. Target is about **4 px/cm**. Vertex score sums to 2; bands: needs photos, almost, done | `CoverageEngine.swift:320-340` |
| Photo detail % | Covered share of observed mesh area. He states it is not "how much of the room is scanned" | `CoverageEngine.swift:54` |
| Photo choice | Holds the sharpest recent frame, takes a photo only if it adds at least **0.06 m²** of uncovered surface | `CaptureController.swift:1409,1465` |
| High-res stills | `captureHighResolutionFrame`, at most one per 3 s, only at nominal thermal state, only if not budget-constrained; kept only if it is wider and at least as sharp (relative) and the pose is within 0.2 m and 12 degrees of the held frame; saved at up to 3024 px | `CaptureController.swift:1421-1465` |
| Blur | Under 1.5 px smear at 1920 wide is sharp, up to 6 px is accepted | `CaptureController.swift:1466` |
| Depth | 256x192 Float16, raw DEFLATE (`.f16z`), plus UInt8 confidence plus a **640x480 JPEG of the same frame**, up to 5 per second, with its own pose and intrinsics | `README.md`, `DepthRecorder` |
| Stop hint | `coveragePlateau`: coverage at least 65%, more than 120 s in, and no progress for 45 s | `CaptureController.swift:642` |
| Budget | `CaptureBudget` from thermal state, photo count and memory pressure sets depth and evaluation intervals | `CaptureController.swift:647` |
| RoomPlan data | Saves `CapturedRoom` JSON (Codable), USDZ (parametric and mesh) and raw `CapturedRoomData`, so RoomBuilder can be re-run later | `ScanBundle.swift` |
| Mesh PLY | Binary: xyz, normal, **coverage**, rgb, `inroom`, per-face ARKit class | README |
| Untrusted bundles | Manifest paths are checked against escaping the folder on import | `ScanBundle.exportRoom` |

The coverage score and the plateau rule are small, self-contained and worth reimplementing; they are what our
`CapturePolicy` lacks (we gate on motion and sharpness, not on whether a photo adds coverage). MIT licence: reuse is
allowed with the copyright notice kept, but reimplement against our own types instead of pasting, since his code is
built around RoomPlan and houses.

## 3. Gap analysis against 3lay (`3lay-lidar/2`)

| Idea | Ours today | Verdict |
| --- | --- | --- |
| Mesh + posed photos + depth + confidence | Done (v2, validated) | Keep |
| Depth frames **independent of photos** (1,112 depth vs 165 photos) | Depth only for saved photos | **Adopt.** Depth is cheap; photos are not. Store depth keyframes with their own pose. Additive, so `3lay-lidar/3` |
| High-res stills | Uses the 1920x1440 ARKit frame; listed under "Not in this format yet" | **Adopt** `captureHighResolutionFrame`. `depth.timeOffset` is already specified for this |
| Float16 depth | Float32 | Optional: halves depth size. Only if bundle size hurts |
| Red/green coverage on the mesh | Counts only | **Adopt.** Coverage per mesh face: seen by at least N photos within an angle range |
| Photo-detail gauge and "no longer improving" stop hint | None | **Adopt.** Stop on marginal gain, which also limits heat and size |
| Adaptive load shedding | `CapturePolicy` thermal intervals | Already partly there; surface it to the user |
| RoomPlan layout sidecar | None | **Adopt for rooms only** (section 4) |
| LLM render-and-compare loop | None | Same idea as role C in `AI_ASSIST_PLAN.md`, applied to rooms or to print models. A separate skill, not app code |
| Three.js viewer and knolling | None | **Out of scope** for a 3D-printing product unless you want rooms as a product line |

## 4. RoomPlan: where it makes sense

- **Rooms and large objects: yes, as an extra sidecar.** `CapturedRoom` is Codable. Save `room/room.json` (and
  optionally its USDZ) beside the bundle. It gives walls, openings and furniture boxes with real dimensions: a good
  skeleton to check the mesh against. iOS 17 added `RoomCaptureSession(arSession:)` so it can share the ARSession with our mesh and
  photo capture *(verify)*; two sessions fighting over the camera is the thing to avoid.
- **Do not replace the ARKit mesh with RoomPlan.** RoomPlan outputs parametric boxes and planes, not a surface; our
  mesh and photos are the data a reconstruction needs.
- **Small objects: no.** RoomPlan recognises room-defining things (walls, doors, windows, about 16 furniture
  categories) and, per an Apple forum answer, mostly ignores objects on a table, pointing to Object Capture instead
  ([Apple forums](https://developer.apple.com/forums/thread/771832)). There is no minimum size documented, but it is
  the wrong tool, and its scene-size errors are known to be unreliable. **Object Capture stays the small-object path.**
- Needs iOS 17 or later and a LiDAR device (`RoomCaptureSession.isSupported`).

## 5. What the ideas mean for small objects

The useful parts carry over, the room parts do not:

- Coverage feedback (red/green) on the **object** during Object Capture. Object Capture has its own guidance UI, so
  this is a smaller win there; it matters most in our LiDAR mode.
- High-res stills with the depth sidecar: Object Capture takes depth per image (`PhotogrammetrySample.depthDataMap`).
- Photo-detail gauge and stop-when-no-gain.
- Render-from-photo-pose compare as a QA step on the finished model (AI plan, role C).

## 6. Proposed phases

1. **Compare formats** (`photos.json` and `depth/frames.json` against `LidarManifest`, done in 2b) and scan one room
   with both apps to compare triangle counts.
2. **Format `3lay-lidar/3`** (additive): depth keyframes with their own poses, optional high-res stills, optional
   `room/room.json`. Validator and `docs/LIDAR_BUNDLE.md` updated first, with tests.
3. **Capture UX** in `LidarCapture`: coverage per mesh face, photo-detail gauge, stop-on-no-gain hint.
4. **High-res stills**, then depth keyframes at their own rate.
5. **RoomPlan sidecar** for room scans only, behind `RoomCaptureSession.isSupported`.
6. **Mac side:** read the depth and room sidecars; use depth for scale and alignment (already on the backlog).

## 7. Caveats

- This repo has no Swift toolchain in the cloud session, so ARKit and RoomPlan code cannot be compiled or run here.
  CI on macOS (`.github/workflows/apps.yml`) is the only check until it is run on a device. Capture UX needs a phone.
- His accuracy claims ("modeled to the inch") are marketing next to his own 2.6 cm wall error, and furniture is
  boxes with the detail inferred by the model. Do not promise print-grade accuracy from this pipeline.
- The model names in the video could not be verified and do not matter to the capture design.
