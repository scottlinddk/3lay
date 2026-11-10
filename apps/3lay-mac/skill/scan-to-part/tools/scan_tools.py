#!/usr/bin/env python3
"""Helpers for the scan-to-part skill. Needs Python 3 and numpy.

  scan_tools.py measure scan/scan.stl [--z 5,10,20]
  scan_tools.py render  part.stl out_dir --like scan/scan.json [--beside scan/scan.stl]
  scan_tools.py compare scan/scan.stl part.stl

All lengths are millimetres. Meshes are STL (binary or ASCII), Z up.
"""
import argparse
import json
import os
import struct
import sys
import zlib

import numpy as np


def load_stl(path):
    """Returns triangles as an (n, 3, 3) float array."""
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) >= 84:
        count = struct.unpack_from("<I", data, 80)[0]
        if len(data) == 84 + count * 50:
            records = np.frombuffer(data, dtype=np.dtype([("n", "<f4", 3), ("v", "<f4", (3, 3)), ("a", "<u2")]), count=count, offset=84)
            return records["v"].astype(np.float64)
    points = [[float(x) for x in line.split()[1:4]] for line in data.decode("utf-8", "replace").splitlines() if line.strip().startswith("vertex")]
    if not points or len(points) % 3:
        sys.exit(f"{path}: not a readable STL")
    return np.array(points, dtype=np.float64).reshape(-1, 3, 3)


def areas_and_normals(triangles):
    cross = np.cross(triangles[:, 1] - triangles[:, 0], triangles[:, 2] - triangles[:, 0])
    length = np.linalg.norm(cross, axis=1)
    normals = cross / np.maximum(length, 1e-12)[:, None]
    return length / 2, normals


def sample_surface(triangles, count, seed=0):
    """`count` points spread evenly over the surface, and the triangle each came from."""
    areas, _ = areas_and_normals(triangles)
    if areas.sum() <= 0:
        sys.exit("The mesh has no surface.")
    rng = np.random.default_rng(seed)
    index = rng.choice(len(triangles), size=count, p=areas / areas.sum())
    u, v = rng.random(count), rng.random(count)
    flip = u + v > 1
    u[flip], v[flip] = 1 - u[flip], 1 - v[flip]
    chosen = triangles[index]
    points = chosen[:, 0] + u[:, None] * (chosen[:, 1] - chosen[:, 0]) + v[:, None] * (chosen[:, 2] - chosen[:, 0])
    return points, index


def measure(args):
    triangles = load_stl(args.mesh)
    points = triangles.reshape(-1, 3)
    low, high = points.min(axis=0), points.max(axis=0)
    areas, _ = areas_and_normals(triangles)
    volume = np.einsum("ij,ij->i", triangles[:, 0], np.cross(triangles[:, 1], triangles[:, 2])).sum() / 6
    print(f"triangles: {len(triangles)}")
    print(f"min:  {low[0]:.2f} {low[1]:.2f} {low[2]:.2f}")
    print(f"max:  {high[0]:.2f} {high[1]:.2f} {high[2]:.2f}")
    print(f"size: {high[0] - low[0]:.2f} x {high[1] - low[1]:.2f} x {high[2] - low[2]:.2f} mm")
    print(f"surface: {areas.sum():.1f} mm2, enclosed volume: {abs(volume):.1f} mm3 (only meaningful for a closed mesh)")
    if args.z:
        samples, _ = sample_surface(triangles, 400_000)
        band = max((high[2] - low[2]) / 200, 0.05)
        for z in [float(value) for value in args.z.split(",")]:
            near = samples[np.abs(samples[:, 2] - z) < band]
            if len(near) == 0:
                print(f"z = {z:.2f}: no surface")
                continue
            lo, hi = near.min(axis=0), near.max(axis=0)
            print(f"z = {z:.2f}: X {lo[0]:.2f} to {hi[0]:.2f} ({hi[0] - lo[0]:.2f}), Y {lo[1]:.2f} to {hi[1]:.2f} ({hi[1] - lo[1]:.2f})")


def write_png(path, pixels):
    """Greyscale PNG from a 2D uint8 array, with only the standard library."""
    height, width = pixels.shape
    raw = b"".join(b"\x00" + pixels[row].tobytes() for row in range(height))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def draw(triangles, view, size):
    """The same picture 3lay Mac draws: straight on, no perspective, light where the surface faces you."""
    right, up, toward = (np.array(view[key], dtype=np.float64) for key in ("right", "up", "toward"))
    centre, span = np.array(view["centre"], dtype=np.float64), float(view["spanMm"])
    areas, normals = areas_and_normals(triangles)
    # Enough points that every pixel the surface covers gets several.
    per_mm2 = (size / span) ** 2 * 6
    count = int(min(6_000_000, max(200_000, areas.sum() * per_mm2)))
    points, index = sample_surface(triangles, count)
    local = points - centre
    x = np.floor(local @ right / span * size + size / 2).astype(np.int64)
    y = np.floor(size / 2 - local @ up / span * size).astype(np.int64)
    depth = local @ toward
    grey = (40 + 190 * np.minimum(1, np.abs(normals[index] @ toward))).astype(np.uint8)
    inside = (x >= 0) & (x < size) & (y >= 0) & (y < size)
    pixel, depth, grey = (y * size + x)[inside], depth[inside], grey[inside]
    order = np.argsort(depth)  # nearest last, so it wins
    image = np.full(size * size, 255, dtype=np.uint8)
    image[pixel[order]] = grey[order]
    return image.reshape(size, size)


def render(args):
    with open(args.like) as handle:
        package = json.load(handle)
    triangles = load_stl(args.mesh)
    beside = load_stl(args.beside) if args.beside else None
    os.makedirs(args.out, exist_ok=True)
    for view in package["views"]:
        size = int(view["pixels"])
        picture = draw(triangles, view, size)
        if beside is not None:
            # Scan on the left, your part on the right, same scale and camera.
            picture = np.hstack([draw(beside, view, size), np.full((size, 8), 0, dtype=np.uint8), picture])
        path = os.path.join(args.out, f"{view['name']}.png")
        write_png(path, picture)
        print(path)


def nearest(points, others, chunk=1000):
    """Distance from each of `points` to the closest of `others`."""
    a, b = points.astype(np.float32), others.astype(np.float32)
    b2 = (b * b).sum(axis=1)
    best = np.empty(len(a))
    for start in range(0, len(a), chunk):
        block = a[start:start + chunk]
        squared = (block * block).sum(axis=1)[:, None] + b2[None, :] - 2 * block @ b.T
        best[start:start + chunk] = np.sqrt(np.maximum(squared.min(axis=1), 0))
    return best


def worst_places(points, distances, spacing, limit=6):
    places = []
    for index in np.argsort(-distances):
        if len(places) == limit:
            break
        if all(np.linalg.norm(points[index] - points[other]) > spacing for other in places):
            places.append(index)
    return places


def compare(args):
    scan, part = load_stl(args.scan), load_stl(args.part)
    scan_points, _ = sample_surface(scan, args.samples, seed=1)
    part_points, _ = sample_surface(part, args.samples, seed=2)
    size = float((scan.reshape(-1, 3).max(axis=0) - scan.reshape(-1, 3).min(axis=0)).max())
    to_part, to_scan = nearest(scan_points, part_points), nearest(part_points, scan_points)
    # Two random samplings of the very same surface are still this far apart on average.
    floor = float(np.sqrt(sum(areas_and_normals(mesh)[0].sum() for mesh in (scan, part)) / 2 / args.samples) / 2)
    print(f"scan size {size:.1f} mm, sampling noise about {floor:.2f} mm (differences below that mean nothing)")
    for title, distances, points, hint in (
        ("scan -> part", to_part, scan_points, "scan surface with no part surface near it: a feature is missing, or the part is the wrong size or in the wrong place"),
        ("part -> scan", to_scan, part_points, "part surface with no scan near it: material or a feature the real object does not have"),
    ):
        print(f"\n{title}: mean {distances.mean():.2f} mm, 95% within {np.percentile(distances, 95):.2f} mm, max {distances.max():.2f} mm")
        print(f"  worst places ({hint}):")
        for index in worst_places(points, distances, size / 8):
            p = points[index]
            print(f"  - ({p[0]:.1f}, {p[1]:.1f}, {p[2]:.1f}): {distances[index]:.2f} mm")
    score = to_part.mean() + to_scan.mean()
    print(f"\nscore (sum of the two means): {score:.2f} mm = {score / size * 100:.2f}% of the object's size")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    m = commands.add_parser("measure", help="size of a mesh, and its extent at given heights")
    m.add_argument("mesh")
    m.add_argument("--z", help="comma-separated heights to slice at, in mm")
    m.set_defaults(run=measure)
    r = commands.add_parser("render", help="draw a mesh with the same cameras as the scan's pictures")
    r.add_argument("mesh")
    r.add_argument("out")
    r.add_argument("--like", required=True, help="the package's scan/scan.json")
    r.add_argument("--beside", help="another mesh (the scan) to draw on the left of each picture")
    r.set_defaults(run=render)
    c = commands.add_parser("compare", help="distances between the scan and your part, both ways")
    c.add_argument("scan")
    c.add_argument("part")
    c.add_argument("--samples", type=int, default=40_000)
    c.set_defaults(run=compare)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
