---
name: scan-to-part
description: Rebuild a 3lay scan package (scan mesh, straight-on pictures, measurements, photos) as a clean, editable, printable part in OpenSCAD. Use when asked to rebuild, clean up or remodel a scan from 3lay Mac, or when a folder contains scan/scan.json with format 3lay-scan-package.
---

# Scan to part

A 3lay scan package holds a 3D scan of a real object. The scan is a noisy triangle mesh: flat faces are
bumpy, sharp edges are rounded and small holes may be partly filled. Your job is to write a clean
parametric model of the same object, and to show with measurements that it matches the scan.

Treat the scan as measurement evidence and the photos as visual evidence. This is an iterative job:
model, compare against the scan, fix the largest difference, repeat. It is not a one-step conversion.

## What is in the package

```
README.md                 what the person asked for
scan/scan.json            units, bounds, the person's description, and the camera of every picture
scan/scan.stl             the scan: millimetres, Z up, standing on Z = 0, centred on X = Y = 0
scan/views/*.png          the scan seen straight on, without perspective: top, front, right, corner
scan/photos/*.jpg         some of the original photos, when the scan was built from photos
skill/scan-to-part/       this skill and tools/scan_tools.py
```

Read `README.md` and `scan/scan.json` first. Check `format` starts with `3lay-scan-package/`. The
`note` field is what the person said the object is; believe it over your own guess.

Every picture in `scan/views` is `spanMm` wide and high, so sizes can be read off it
(`mmPerPixel` in `scan.json`). Light grey faces the viewer, dark grey is steep. Do not measure in the
`corner` view. Photos have perspective and no scale: use them to recognise features, materials and
what the object is, never for dimensions.

## Tools

`skill/scan-to-part/tools/scan_tools.py` needs Python 3 with numpy. Set `T` to its path.

```sh
python3 "$T" measure scan/scan.stl --z 2,10,18      # size, and X/Y extent at those heights
python3 "$T" render part.stl compare --like scan/scan.json --beside scan/scan.stl
python3 "$T" compare scan/scan.stl part.stl         # distances both ways, and the worst places
```

`render` draws your part with exactly the cameras of `scan/views`, with the scan on the left and
your part on the right of each picture. `compare` prints how far the scan's surface is from yours and
the other way round, and where the largest differences are. It does not judge: you read the numbers
and the pictures.

You also need the `openscad` command to turn your model into an STL. If it is missing, say so and
ask whether to install it (`brew install openscad`). If CadQuery or build123d is already installed
you may use that instead. Do not hand-write an STL.

## Steps

1. **Look.** Open all four views and a few photos. Say in one or two sentences what the object is
   and which features it has (holes, slots, steps, ribs, rounded corners).
2. **Measure.** Run `measure` with heights through every level where the outline changes. Read
   hole positions and diameters from the top, front and right views using `mmPerPixel`. Write the
   numbers down in a table: feature, measured value, where it came from.
3. **Model.** Write `part.scad` in the scan's coordinates (millimetres, Z up, standing on Z = 0,
   centred on X = Y = 0) so it can be compared directly. Put every dimension in a named variable at
   the top. Prefer the simplest shape the evidence supports: flat faces, right angles, round holes,
   `linear_extrude` for a profile that is the same all the way through. Set `$fn = 96;`.
4. **Build.** `openscad -o part.stl part.scad`.
5. **Compare.** Run `render` and `compare`. Open the pictures. Find the largest difference: a
   missing feature, a wrong size, a wrong position.
6. **Fix that one thing** in `part.scad`, then go back to step 4.

Stop when the `compare` score is under about 1% of the object's size and the pictures show no
missing or extra feature, or when two rounds in a row bring no improvement. Five to eight rounds is
normal for a part with a few features.

## Rules

- Take dimensions from the scan. Round to a tidy number (20.0, not 19.87) only when the measurement
  is within about 1% of it, and never to make the model look nicer.
- Model only features you can see in the views or photos. Do not invent holes, chamfers, threads or
  text. A feature you can see but cannot measure goes in the report as approximate.
- The scan cannot see inside. Closed cavities, the depth of blind holes and undercuts are unknown:
  say so, and ask if it matters.
- The underside is the face the object stood on. The scan closes it flat at Z = 0 unless the person
  flipped the object while scanning.
- Small differences everywhere are scan noise, not errors. Do not chase the mean below the
  sampling noise that `compare` prints.
- The scan's scale comes from the phone's LiDAR. It is usually within a percent or so, not exact.
  If the person gives a measured dimension, scale to that and say what you did.
- If the object is organic or sculpted (a figurine, a carved surface), simple solids will not match
  it. Say so after the first comparison and recommend printing the scan itself instead of continuing.
- Never change, move or delete anything under `scan/`.

## What to hand over

- `part.scad` (the editable model) and `part.stl` (ready for the slicer; it can be opened in 3lay Mac
  with Import file).
- The last `compare` output and the side-by-side pictures.
- A short report: what the object is, the dimension table, the final score, and which features are
  measured, which are approximate, and which you left out and why.
