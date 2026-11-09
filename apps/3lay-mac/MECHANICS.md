# Mechanics and evidence

The original executable is `/Applications/BambuStudio.app/Contents/MacOS/BambuStudio` (arm64). The requested `core_target_open`, `native_strings_find`, reference-following, and `native_function_pseudocode` tools are not exposed in this session. The findings below come from `nm`, `strings`, and direct ARM64 disassembly with `objdump`; they are **not pseudocode**. No printer, slicing, or repair formula has been verified.

## Original import path, verified from binary

| Function | Address | Observed rule |
| --- | --- | --- |
| `Slic3r::GUI::Plater::load_files(wxArrayString const&)` | `0x1011859a0` | Named file-loading entry point; behavior beyond the name was not established. |
| `Slic3r::GUI::Plater::load_files(paths, LoadStrategy, bool)` | `0x1011e68dc` | Named overload; behavior beyond the name was not established. |
| `Slic3r::Model::read_from_file` | `0x1004d1c08` | Named model loader; its format dispatch was not decompiled. |
| `Slic3r::load_stl` | `0x10032ee0c` | At `0x10032eec8`, calls `TriangleMesh::ReadSTLFile`; at `0x10032eef8`–`0x10032ef0c`, branches away when the read failed **or** the resulting mesh has zero faces; otherwise calls `Model::add_object` at `0x10032ef68`. |
| `Slic3r::TriangleMesh::ReadSTLFile` | `0x1009898a4` | Calls `stl_open` at `0x1009899a0`; only on success calls `TriangleMesh::from_stl` at `0x1009899e0`. |
| `Slic3r::_BBS_3MF_Importer::_load_model_from_file` | `0x10029b310` | Named 3MF importer; internal rules were not established. |

The STL acceptance rule is mirrored in `Mesh::load`: an import needs vertices and at least one face. A zero-face STL now reports that it contains no mesh data, matching the meaning of the binary string `found no mesh data from stl file`; string presence does not prove the exact UI message path. The binary's CLI usage mentions `.3mf` and `.stl`; that supports format availability, not the full set of accepted formats. No specific printer volume or scale conversion can be inferred from these calls.

Build verification remains unavailable: `cargo build` exits with `command not found: cargo` in this environment. The requested decompiler calls and rebuild check cannot be run until those tools are exposed.

The current companion [3D-scan repository](https://github.com/scottlinddk/3D-scan) now contains a Swift iOS client. `PairingLink.swift` accepts `scan3d://pair?server=https://<host>&token=<device token>` and permits plain HTTP only for localhost. `Submission.swift` uploads photo and capture-bundle artifacts, then creates a `reconstruct` task. The Mac worker writes a `model.usdz` reconstruction. The server exposes `GET /api/jobs`, `GET /api/jobs/{job_id}/artifacts`, and `GET /api/artifacts/{artifact_id}/content`, each requiring `jobs:read`. This app connects to those read endpoints with the same pairing link, downloads the resulting mesh, and asks macOS ModelIO to convert USDZ to STL. macOS ModelIO could not open a synthetic USDZ in this sandbox, so a `usdcat` text fallback was added. That fallback converted a four-triangle USDZ fixture into a 284-byte binary STL with the expected triangle count and first vertex; a real phone capture remains untested. The local Wi-Fi upload page is a separate route for ordinary browser uploads and is not a native companion endpoint.

No printer settings, slicing rules, or mesh repair formulas were recovered from the Bambu executable. Scale is left explicit because the companion architecture warns against guessing units from a model's size.

## Implemented values

| Value | Rule | Source |
| --- | --- | --- |
| LAN port | 8765 | Estimated design choice; no companion desktop endpoint exists |
| Upload limit | 100 MB | Estimated design choice; bounded upload requirement in companion architecture |
| Plate width/depth | 256 mm | Estimated visual placeholder; printer-specific build volume was not verified in target code |
| Screenshot frame | about 120 frames | Craft Anything request |
| Accepted meshes | ASCII/binary STL, OBJ, ASCII PLY; companion USDZ via macOS conversion | Local implementation scope; `Submission.swift` and Mac worker `model.usdz` |

The desktop app does not claim validation, repair, slicing, or printer readiness. Those require authoritative geometry processing and verified printer settings beyond the evidence available here.
