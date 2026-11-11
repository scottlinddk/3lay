# Mac reconstruction baseline

What the Mac measures about each reconstruction, how to benchmark it, and what the export audit found.
**No benchmark numbers are recorded here yet.** They need the physical fixture objects and a Mac; this file
defines the protocol so the numbers are comparable when they exist.

## What every run records

3lay Mac writes `<model>.report.json` next to each model built from photos (`ReconstructionReport`):

| Field | Meaning |
| --- | --- |
| `requestedDetail` / `actualDetail` / `fallbackReason` | The level asked for first (Full, or Raw with Maximum detail on) and the one that produced the model. A lower actual level is also shown in the status line. |
| `photosTotal` / `photosUsed` / `photosSetAsideBlurry` / `photosWithDepth` | What the blur filter did and how many photos carry depth. |
| `durationSeconds` | Wall time of the Object Capture step, including unpack and the blur filter. |
| `peakResidentMegabytes` | Highest resident memory of the app sampled every 0.5 s while it ran. A lower bound of the true peak. |
| `outputBytes`, `triangleCount`, `vertexCount` | The USDZ size and the imported mesh. |
| `extentsMillimeters` | Size along the model's principal axes, largest first (`OrientedExtents`). |

## Protocol

Fixture objects, each with dimensions measured independently (calipers or a CAD model), recorded before scanning:
textured, low-texture, thin-edged, recessed-detail, and a difficult reflective one.

For each object and each setting (Full, Raw): scan once, send the same photos three times, and keep the three reports.

- **Dimensional error:** `DimensionalError.compare(measured:reference:)`, per axis, in mm and %.
- **Repeatability:** `DimensionalError.repeatability(runs:)`, the standard deviation of each extent over the three runs. Report it separately from accuracy: a scan can be consistently wrong.
- **Detail and completeness:** judged by eye against the object (thin edges, recesses, holes), with photos of the result. Not automated.
- **Resources:** duration and peak memory from the reports, on the oldest Mac you support and a recent one.

Oriented (PCA) extents depend on the object having a clear principal axis. Boxy or elongated fixtures are fine; a
sphere or a cube-like shape has no preferred axis, so measure those against reference distances between features instead.
Axis-aligned `Mesh.bounds` is orientation dependent (a 20 mm side of a box turned 45 degrees reads about 84 mm), so it
must not be compared with a ruler.

## Export audit (read from the code, not measured)

| Step | Finding |
| --- | --- |
| Blur filter (`PhotoQuality`) | Sets aside up to 25% of photos and never below 20. That can remove coverage; the count is now in the report. |
| USDZ to STL (`convert_usdz.swift`) | Tries ModelIO's exporter first. Only if that fails does it parse `usdcat` text, which refuses output over 150 MB (roughly 2 to 3 million triangles). A Raw model that reaches that fallback fails with a size message (previously "no supported surface mesh"). Not tested on a Raw model. |
| Units | USDZ metres are multiplied by 1000 in Float32: about 6e-5 mm resolution at 1 m. No loss that matters. |
| Re-centring | A translation to the plate origin. No geometry change. |
| 3MF export | Vertices written as Swift `Float` descriptions, which round-trip exactly. Welding merges only bit-identical vertices and drops triangles that collapse. No smoothing, decimation or cleanup anywhere in the import or export path. |
| STL export | Float32 vertices, zero normals (slicers recompute them). Rotation about Z only. |

Not examined: whether Object Capture itself smooths or fills holes at each detail level. That is Apple's behaviour and
only the fixtures can show it.
