# Core debugging checkpoint — 28 October 2026

## Reproduced failures

The original 13 shared-code tests passed. Two new regression tests then failed against the original implementation:

- A capture folder containing frames but no document.json made the entire library fail to load.
- Rendering zero input frames returned a successful blank panorama.

Evidence: `core-debug-tests.log` and `core-debug-reproductions.log`.

## Changes

- Load valid captures independently. Report unreadable captures in the library while retaining their files. Verify that document IDs match their storage folders. The store supports isolated temporary roots for regression tests.
- Reject empty stitches, invalid output dimensions, truncated pixel storage, invalid projections, and malformed camera matrices before indexing arrays, allocating output, or submitting GPU work.
- Extract capture timing into the shared CaptureTrigger used by the app. Reset the whole candidate timer after tracking/motion interruptions; require leaving a completed target before another retake.
- Ignore samples after capture stops, invalidate pending permission requests, clear callbacks, stop heading/location updates, and reset AR motion history on restart. An in-flight photograph may finish saving after close, but must not relock the camera or emit capture feedback. Freeze the first frame's yaw reference while its disk write is pending.
- Use one heading reliability rule for both orientation math and the exported reference label, including negative/nonfinite accuracy and invalid headings.
- Export only raw frames named in committed records. Keep orphaned/undone originals on disk for recovery. Add cooperative cancellation between archive files and clean incomplete export packages on failure.
- Prevent overlapping library jobs and show progress/cancellation when exporting from the panorama detail screen.

## Verification

`swift test -c release`: **22 tests passed, zero failures** (17 core/viewer + 5 geometry/synthetic). This includes actual Mac GPU/CPU comparison, SceneKit rendered texture versus tap-ray checks, timing interruptions, storage recovery, invalid stitch input, raw-frame export selection, JPEG metadata, and ZIP integrity.

Synthetic 2048 panorama: MAE 0.01836, horizontal shift 1 pixel, seam error 0.00689, coverage 100.00%. These are synthetic measurements, not real-scene camera quality measurements.

Evidence: `core-debug-final-tests.log`.

iOS app, framework, and test bundle compile/link against the simulator SDK with `Assets.xcassets` and `Stitch.metal` excluded. This checks Swift integration, including the ARKit capture view model, but does not validate the excluded resources or simulator execution. Evidence: `core-debug-ios-final.log`.

The full unsigned device build fails because the active Xcode 27.1 installation lacks its Metal Toolchain. Installation was started with `xcodebuild -downloadComponent MetalToolchain`; its progress is in `core-debug-metal-install.log`. Full build evidence: `core-debug-device-build.log`.

There is no available iOS simulator runtime and no connected iPhone. No live app walkthrough or camera test was possible. Earlier Xcode 26.3 verification in TEST_REPORT.md describes a different toolchain state.

## Remaining checks

After the toolchain and runtime installations finish, run the full build/test and visually exercise onboarding, sample loading, panorama gestures, hotspot editing, and export/cancellation. Then verify real-device alignment, exposure locks, stop/restart behavior, heading/gyro direction, memory use, and real-world seams. The capture lifecycle changes compile but still require this hardware validation.
