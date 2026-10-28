# Stitch quality checkpoint — 28 October 2026

## Reported problem

A real indoor capture stitched with translucent "ghost" objects, doubled edges, a milky haze around the windows, and a soft image in the viewer.

## Causes found

1. The blend averaged every overlapping frame with squared edge weights. Any pose error or parallax therefore produced double images and haze.
2. Poses came from ARKit alone. The optional refinement was a coarse yaw/pitch grid search and was off by default.
3. Photometric compensation fitted a luminance gain only. Veiling glare from a window adds light (an offset), which a gain cannot represent.
4. The recorded focal length was treated as exact. A 1% error misregisters frame edges by several pixels, and rotations cannot absorb it.
5. The viewer decoded at most 4096 px and sampled without mipmaps. The default 4096 output is shown about 1.3× magnified at the default zoom.
6. The finishing pass was mild and could not lift haze.

Defects found in review:

- Re-stitching appended duplicate "CPU fallback" and "Incomplete coverage" notes.
- A truncated frame smaller than 2 px in the working image could index out of range in alignment, which runs before render validation.
- The Metal path held three full copies of the frames at peak.

## Changes

- `Alignment` matches Shi–Tomasi corners by NCC against pose-predicted neighbour warps, rejecting ambiguous peaks. A Huber-weighted Gauss–Newton bundle adjustment then solves all rotations plus one shared focal scale, with 1.5° and 5% priors.
- `Reprojection.compensate` fits a per-channel gain and offset in linear light. It uses robust reweighting and a hard gauge (mean gain 1, mean offset 0), and works in place.
- Blending is two-band on CPU and Metal. Both bands prefer the most central frame: the low band hands over over a few percent of frame width, and the detail seam is a few pixels wide. Frames ramp in from their margin.
- `Enhancement` adds area-weighted levels with a limited stretch, and a CLAHE dehaze on luminance. It uses wrapping tiles, curves that preserve each tile's mean, and highlight protection. Core Image then adds vibrance 0.15, light denoise and sharpening.
- Viewer: full-resolution texture with trilinear, anisotropic sampling. New captures default to 6144 px.
- Fixes: stitch notes are replaced on each stitch; truncated photographs are rejected; frames are copied straight into Metal buffers; compensation no longer duplicates frame memory.

## Verification

| Check | Result |
|---|---|
| `swift test -c release` (macOS) | 33 tests, 0 failures. Log: `stitch-quality-tests.log` |
| `xcodebuild test`, iOS 27.1 simulator, iPhone 18 Pro Max | 33 tests, 0 failures; the Metal/CPU agreement test executed. Log: `stitch-quality-simulator-tests.log` |
| Generic iOS device build and build-for-testing, Xcode 27.1 | Succeeded with no Swift warnings |
| 2° yaw/pitch + 1° roll pose error | 2.781° → 0.008° relative pose error, 0.15 s |
| 2% focal-length error | Recovered to 1.0000× true; pose error 0.011° |
| Veiling glare on half the frames | Inconsistency after a global affine fit 0.0388 → 0.0068 |
| Dehaze of a veiled scene | Textured-area σ 21 → 36; dark percentile 145 → 121; white wall stays white (230 → 251) and neutral |

Old and new blending give identical error once frames are compensated (0.0216 vs 0.0216 MAE). The synthetic reconstruction's raw MAE moved from 0.019 to 0.027. This is a global brightness choice: the fixture's ±15% sRGB gains average about +4% in linear light. Inconsistency after a global affine fit improved (0.0201 → 0.0195).

The enhancement parameters were chosen by comparing 1:1 crops of a real stitched indoor panorama. That image is not committed.

## Not verified

- No iPhone was connected. Capture → stitch with the new pipeline has not run on real frames, and 6144 px time and memory on device are unmeasured.
- Parallax from objects closer than about 1.5 m cannot be removed by rotation-only stitching. Seams are placed by frame centrality, not routed around objects.
