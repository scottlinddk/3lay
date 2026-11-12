# Plan: ideas from Wes Bos's "3D Model Anything", RoomPlan, and small objects

Status: **proposal, nothing implemented.** Written 2026-11-12. Companion to `AI_ASSIST_PLAN.md`.

Sources: the video transcript supplied by the user, a screenshot of his app (v4 scan "Office"), and a secondary
write-up ([BestHub](https://www.besthub.dev/articles/iphone-lidar-scan-ai-walkable-three-js-room-in-browser-2-6k-stars-in-13-days-902b7cd8778a)).
His repo (`github.com/wesbos/3d-model-anything`, app in `apps/house-capture`) was **not readable** from this session,
so everything about its code is second-hand. Read the repo before copying anything.

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

Not stated in the video. The secondary source gives, for his office: **501,651 triangles, 165 photos, 1,112 depth
frames** (the screenshot shows 161 photos in the v4 scan). It gives no vertex count, and "points" is not a number
ARKit reports, so compare **triangles**. That is about what ARKit's scene mesh produces for a room: the same
hardware as ours, so the mesh itself is not his advantage. Our app already shows `triangleCount` while scanning; scan
the same room and compare before drawing conclusions. His own stated wall-plane error is **2.6 cm**: good for furniture,
not construction, and not what a 3D print needs.

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

1. **Read his repo** (needs access) and diff its `frames.json`/manifest against `LidarManifest`; confirm his triangle
   and depth numbers by scanning one room with both apps.
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
