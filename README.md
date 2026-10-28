# MIRAS Capture

An iPhone app for guided 360° **photographs**, on-device pose-based stitching, heritage hotspots, and MIRAS viewer packages. SwiftUI, iOS 17+, portrait only, Apple frameworks only.

## Open and run

```sh
brew install xcodegen
xcodegen generate
open MIRASCapture.xcodeproj
```

Select the MIRASCapture app target, choose your signing team under Signing & Capabilities, select a supported real iPhone, and Run. The generated Xcode project is disposable; `project.yml` is the source of truth. A recent Xcode with the iOS SDK, simulator runtime, and Metal toolchain installed is required. Xcode 26 can install the compiler with `xcodebuild -downloadComponent MetalToolchain`.

Camera capture uses ARKit and requires a real iPhone. The app offers a clear recovery message when capture is unavailable. On the simulator, finish onboarding, then **long-press “MIRAS Capture” in the navigation bar** and choose **Load sample capture**. You can preview, place/edit/move/delete hotspots, and share the ZIP to Files. The other debug action runs the CPU synthetic stitch and displays its image and metrics.

## Architecture

```text
SwiftUI library / capture / preview / hotspot editor
                  |
        @Observable view models
                  |
   CaptureService    HeadingService
       ARKit         CoreLocation
                  |
        CaptureStore (actor)
                  |
     StitchService (background actor)
     Geometry reprojection + Metal kernel
     Core Image / Accelerate / ImageIO
                  |
     ExportService (actor) -> Photos / ZIP / Files share sheet

Geometry: Foundation-only vectors, spherical math, shot planning,
          raster projection, overlap gains, synthetic fixtures
```

Each capture lives in Application Support at `Captures/<uuid>/`. `document.json` stores the app's library state, `frames.json` stores exact-frame transforms, intrinsics, dimensions, exposure duration and timestamps, and `frames/NNN.jpg` stores sensor-orientation photographs. `panorama.jpg` is generated during stitching. Relaunch the app and use Re-stitch to process saved frames again.

Swift Package Manager also builds the same math, image codecs, store, stitcher, mesh and export services on macOS. It is a verification harness, not an extra app or third-party dependency.

## Capture

1. Stand in one place and keep the **camera lens** over the same physical point.
2. Follow the white dots. The next target pulses; completed dots become green.
3. Align the ring and hold steady. The first target allows at least a second for auto exposure; later shots require 300 ms below 6°/s and 2.5° angular error, with normal tracking.
4. Move away from a completed dot, return to it, and hold for a second to retake. Undo removes the last recorded shot.
5. Finish becomes available after all non-polar rows are complete. Zenith/nadir may be captured too; nadir is optional.

The planner derives its layout from the actual intrinsics. It uses the camera's smaller field of view conservatively so the plan remains covered across phone roll; the number of photographs can exceed the illustrative 30-shot layout in the prompt. The coverage test samples 10,000 directions with an additional edge margin.

ARKit high-resolution capture is attempted first, with an AR video-frame fallback recorded in capture warnings. Exposure, white balance and focus lock after the first saved frame. True heading is used only with accuracy between 0° and 15°; otherwise yaw zero follows the first shot. GPS is optional. A denied location permission does not block capture.

Avoid nearby foreground objects, moving people, mirrors and low-texture areas. Translation over 8 cm prompts coaching. The camera must rotate in place; pose-only stitching cannot remove parallax.

## Stitching and preview

Choose 2048, 4096 or 6144 pixels of panorama width in capture settings; new captures default to 6144, which matches the decoded frames' angular resolution and shows about 1:1 at the viewer's default zoom. Each output direction is reprojected into the recorded cameras with their actual sensor intrinsics. The pipeline is: align → photometric compensation → two-band render → hole fill → enhancement → optional cap.

**Alignment** (`Alignment`) corrects the ARKit poses from image content. For every overlapping pair, Shi–Tomasi corners in one frame are matched by normalized cross-correlation against the neighbour resampled through the recorded poses (coarse-to-fine, sub-pixel, rejecting ambiguous peaks from repeating patterns such as patterned curtains). A robust bundle adjustment (Gauss–Newton, Huber weights, outlier removal) then solves every frame's rotation plus one shared focal-length scale, anchored to the recorded poses with a 1.5° prior (5% for focal length) so textureless frames keep their sensor pose. Two rounds run: a ±2.5° search (±6° with **Wide alignment search**), then ±0.75° on the corrected warps. On the synthetic tests it recovers 2° yaw/pitch plus 1° roll error to 0.008°, and a 2% intrinsics error exactly.

**Photometric compensation** (`Reprojection.compensate`) solves a per-channel gain and offset for every frame in linear light from robustly reweighted overlap samples, with the mean gain held at 1 and the mean offset at 0. The offset models veiling glare: frames facing a bright window carry a light veil that a gain alone cannot remove. Corrections are baked into the frame pixels.

**Blending** is two-band. Both bands prefer the most central frame: smooth colour (below roughly 8 source pixels) hands over within a few percent of frame width, and detail switches with a seam a few pixels wide. Overlaps therefore never average two slightly different images, which is what produced translucent ghosts and haze. Frames enter the blend from zero weight at their 4% margin. Metal processes 64-row batches with progress and cancellation; the same CPU math is used when Metal is unavailable. Decoded frames are limited to a 1280-pixel long edge to reduce working memory; full-resolution originals stay on disk and can be exported.

**Enhance colour and detail** (on by default) dehazes and finishes the panorama: area-weighted levels with a limited stretch, then contrast-limited adaptive histogram equalization (CLAHE) on luminance in 16 × 8 tiles that wrap across the 360° seam. Each tile curve keeps its tile's mean brightness and highlights are progressively protected, so white walls and ceilings stay white and neutral surfaces stay neutral. Core Image then adds light vibrance, noise reduction and luminance sharpening, also wrapped across the seam. Parameters were tuned on a real indoor capture with backlit windows.

Uncovered pixels receive a nearest-valid fill softened with an Accelerate box blur. Coverage is measured **before** this fill, excluding the bottom 10° nadir cap. A circular MIRAS logo cap is optional. The JPEG includes GPano XMP tags; a true-north panorama has `PoseHeadingDegrees=0`. Saving to Photos requests add-only permission. If Photos access fails, the panorama remains in the app and can still be exported to Files.

The inward-facing SceneKit mesh uses explicit MIRAS UVs and shows the panorama at its full stitched resolution with mipmapped, anisotropic sampling. Drag to look, pinch between 40° and 100° vertical FOV, or toggle gyro. Pitch is limited to ±85°. Tap to create a hotspot; drag a dot to move it; open a list row to edit; swipe a row to delete. Nearby dots produce a 12° proximity warning. Required title/caption, the 300-character caption limit, and HTTP/HTTPS source URLs are validated before export.

## MIRAS package

The share sheet exports a standard, uncompressed ZIP with CRC32 validation and one top-level slug folder. Choose **Save to Files** to retain it. The unpacked export folder is also retained beside the temporary ZIP during the share operation.

```text
<slug>/
  panorama.jpg
  capture.json
  hotspots.json
  frames/             # optional originals
  frames.json         # optional pose records
```

`capture.json` contains app version, hardware model identifier, capture date, frame count, actual JPEG dimensions, yaw reference, heading/accuracy, GPS/accuracy, stitch settings, coverage (0–1), and warnings. Last stitch settings are retained separately from settings changed before a re-stitch. Location may be absent. The device model is the hardware identifier (for example, `iPhone14,5`); simulator exports record the simulated device identifier.

`hotspots.json` uses the MIRAS schema:

```json
{
  "defaults": {
    "triggerAngle": 8, "exitAngle": 11,
    "hoverAngle": 3, "hoverExitAngle": 4.5,
    "dwellTime": 700, "duration": 8000, "cooldown": 4000
  },
  "hotspots": [
    {
      "id": "unique-kebab-case-id", "view": "capture-slug",
      "title": "Gateway", "yaw": 0, "pitch": 15,
      "caption": "Carved stone entrance.", "sources": []
    }
  ]
}
```

Yaw is clockwise, 0–360 with 360 wrapped to 0, rounded to one decimal. Pitch is up positive, rounded to one decimal. UV mapping is `u = wrap(0.5 + yaw/360)` and `v = 0.5 - pitch/180`. Output image dimensions are read from the JPEG, so editing a future stitch size does not mislabel an existing export.

## Verification

```sh
# Executes shared production math and core services on the Mac:
swift test -c release

# Full iOS test run, after installing an iOS Simulator runtime:
xcodegen generate
xcodebuild -scheme MIRASCapture \
  -destination 'platform=iOS Simulator,name=iPhone 15' build test
```

If iPhone 15 is not available, create that simulator in Xcode's Devices and Simulators window, or substitute an available iPhone from `xcrun simctl list devices available`. Simulator test builds use optimized Swift to keep the synthetic workload practical.

Tests cover coordinate inverses and poles, heading fallback, 10,000-direction coverage, tap rays, a labelled synthetic panorama with 1920×1440 virtual cameras and deterministic pose/exposure perturbations, GPU versus CPU output, cancellation, north-referenced saved pose records, GPano metadata, exact exported JSON keys, ZIP paths/CRCs, and rendered preview/tap-ray agreement at multiple screen positions. The synthetic seam metric measures excess discontinuity over the local image gradient; an additional test compares identical rays on both sides of ±180°.

See `TEST_REPORT.md` for commands, measured results, and environment limitations. Milestone checkpoints are in `checkpoints/`.

## Known limitations and next device checks

- This is a 360° **photo** app. There is no 360° video capture.
- Pose-based stitching cannot correct parallax near the lens or moving-person ghosting. Gain compensation handles global brightness differences, not local lighting changes.
- The nadir fill is synthetic and cannot reconstruct a missing floor. Covered areas remain photographic.
- Real-device verification is required for ARKit tracking, high-resolution capture and fallback, camera locks, true heading, Photos permissions, and the CoreMotion magic window.
- The 15-second target for 4096×2048 on iPhone 13 has not been measured. Benchmark GPU time, working memory and temperature on a device before release.
- The conservative planner and 1280-pixel frame decode trade capture count and peak detail for reliable coverage and memory use. Tune these only against device measurements.
- ZIPs use the standard 32-bit format; packages beyond 4 GB are rejected with a recovery message to omit raw frames.
- UI layout and accessibility need a complete simulator/device walkthrough before distribution. The placeholder icon and procedural grid are local generated assets; replace them for production.
