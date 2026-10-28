# Codex prompt: MIRAS Capture (iOS)

Paste everything below the line into Codex as the first message. Run it from a new, empty folder, for example `~/Developer/MIRASCapture`, and attach (or copy into that folder) `MIRAS_VR_Test_Panorama.png` from the MIRAS project so the stitcher self-test has a real image.

---

You are a senior iOS engineer (Swift, SwiftUI, ARKit, AVFoundation, Metal, Core Image). Build a complete, working iOS app called **MIRAS Capture** in this empty folder. Work autonomously through every milestone below. Do not stop after scaffolding or after a plan: write the code, build it, run the tests, fix failures, and only then report.

## 1. What the app does

MIRAS is a heritage-tourism VR project. Its viewer (Three.js and WebXR) shows 360° equirectangular panoramas with gaze-triggered "hotspot" dots and captions. This app lets **any visitor with an iPhone create such a 360° panorama** without a 360° camera, then tag hotspots and export a package the MIRAS viewer can load.

Flow:
1. **Capture.** Guided "connect the dots" capture. Dots are placed on an invisible sphere around the user, and the user turns on the spot to aim the centre reticle at each dot. The app fires automatically when aligned and steady.
2. **Stitch.** All shots are combined on-device into one 2:1 equirectangular image, using the camera orientation ARKit recorded for every shot.
3. **Preview.** Look around the result inside the app: drag, plus gyroscope "magic window".
4. **Tag.** Tap to add hotspot dots with a title and caption.
5. **Export.** A MIRAS package (panorama JPEG + `capture.json` + `hotspots.json`), saved to Files and shareable. The panorama is also saved to Photos as a 360° photo.

Important truth to respect: a single-lens phone produces a 360° **photo**, not a 360° video. Do not attempt video.

## 2. Hard constraints

- **iOS 17+, iPhone only, portrait only.** Swift 5.9+, SwiftUI, Swift Concurrency.
- **No third-party dependencies.** Apple frameworks only: ARKit, RealityKit or SceneKit, AVFoundation, CoreMotion, CoreLocation, CoreImage, Metal, Accelerate, ImageIO, Photos, UniformTypeIdentifiers.
- **Project generation via XcodeGen.** Create `project.yml`; the user runs `brew install xcodegen && xcodegen generate`. Do not hand-write a `.pbxproj`. Include the required Info.plist keys: `NSCameraUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `UIRequiredDeviceCapabilities` = `arkit`, and `UISupportedInterfaceOrientations` portrait only.
- ARKit needs a real device. Everything that does not need the camera **must build and pass tests on the iOS Simulator.** See the self-test in §7.
- Clean architecture: SwiftUI views → `@Observable` view models → services (`CaptureService`, `StitchService`, `ExportService`, `HeadingService`). Pure math in a `Geometry` module with no UIKit/ARKit imports, so it is unit-testable.
- Never block the main thread. Stitching runs in a background `Task` with progress reporting and cancellation.

## 3. Coordinate conventions (must match the MIRAS viewer exactly)

- **yaw**: degrees, clockwise when seen from above, 0 = the panorama's horizontal centre. **pitch**: degrees, up positive, range −90…90.
- Equirectangular mapping: `u = 0.5 + yaw/360` (wrapping into 0…1), `v = 0.5 − pitch/180` with v = 0 at the top row.
- Panorama centre (yaw 0) = **true north** when a reliable heading is available. Otherwise it is the direction the user faced for the first shot; record which one in `capture.json` (`"yawReference": "trueNorth" | "firstShot"`).
- Conversions must be unit-tested both ways: yaw/pitch ↔ unit vector ↔ (u, v) ↔ pixel. Include wrap-around at u = 0/1 and the poles.

## 4. Milestone A: guided capture

**Session.** `ARWorldTrackingConfiguration`, gravity-aligned. Use `ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera` to **lock exposure, white balance and focus** after the first shot, so frames match and seams don't show. Before that, run auto-exposure for about 1 s on the first target.

**Shot layout.** Compute from the actual camera field of view (from `ARCamera.intrinsics` and the image resolution), with about 30% overlap. A typical result for a 26 mm wide camera in portrait:
- pitch 0°: 12 shots every 30°
- pitch +45°: 8 shots every 45°
- pitch −45°: 8 shots every 45°
- zenith +90°: 1 shot
- nadir −90°: 1 shot, optional; it can be skipped because the user's feet are there

Generate the layout in code (`ShotPlanner`), not as hard-coded numbers, and unit-test that every direction on the sphere is covered by at least one planned shot's field of view (sample 10,000 directions).

**AR guidance UI** (RealityKit or SceneKit overlay plus SwiftUI HUD):
- Each target is a white dot about 1.5 m away. The next suggested target is larger and pulses; completed targets turn green and shrink.
- A centre reticle ring fills as alignment improves.
- An arrow at the screen edge points to the next target when it is off-screen.
- A progress counter ("14 / 30") and a small sphere minimap showing done and remaining shots.

**Auto-shutter.** Fire when all of these hold:
- angular error to a remaining target < 2.5°
- angular velocity < 6°/s for 300 ms
- `ARCamera.trackingState == .normal`

Then capture with `ARSession.captureHighResolutionFrame` and fall back to `currentFrame.capturedImage`. Play a light haptic and a shutter flash. Store the image (HEIC or JPEG, quality 0.92) and the camera `transform` and `intrinsics` **at that exact frame**.

**Live coaching** (short text banners):
- "Turn around the phone, not your body": shown when camera translation from the first shot exceeds 8 cm. This is the main cause of parallax seams.
- "Hold still": shown when the phone is moving too fast.
- "Too dark": shown when the mean luma is low.
- "Tracking lost, point at a textured area".

The user can **retake** any shot by aiming at a green dot and holding for 1 s, can undo the last shot, and can finish early once the horizon row and both ±45° rows are complete.

**Heading and location.** `CLLocationManager` true heading and accuracy at the first shot, plus GPS coordinates. Convert ARKit yaw to true north using the heading at the first shot. If heading accuracy is worse than 15°, fall back to `firstShot`.

**Persistence.** Each capture is a folder in Application Support: `Captures/<uuid>/frames/NNN.jpg` plus `frames.json` (per frame: index, target yaw/pitch, 4×4 transform, 3×3 intrinsics, image size, timestamp, exposure). Captures survive app relaunch and can be re-stitched.

## 5. Milestone B: on-device stitching (pose-based, no feature matching)

The orientation of every frame is known from ARKit, so stitch by **reprojection**, not feature matching. This is robust and needs no OpenCV.

1. Output canvas: equirectangular **4096 × 2048** (configurable: 2048, 4096, 6144).
2. For each output pixel: compute the direction (yaw, pitch) → unit vector in the panorama frame → rotate into each frame's camera space using that frame's transform → project with its intrinsics. If the projection lands inside the image (with a 4% margin), sample it bilinearly.
3. **Blending.** Weighted average with feathered weights (weight = distance to the nearest image edge, raised to the power 2), so seams fade instead of cutting.
4. **Exposure compensation.** Estimate one gain per frame from the mean luminance in overlap regions (least squares), then apply it before blending.
5. **Optional refinement** (behind a setting, off by default): small rotation corrections per frame, found by maximising normalised cross-correlation in overlaps on a downscaled canvas. Keep it simple and bounded (±1.5°).
6. **Holes.** If no frame covers a pixel (usually the nadir), fill it with a soft blur of the nearest valid pixels and offer an optional circular "MIRAS" logo cap at the nadir.
7. **Performance.** Implement the reprojection and blending as a **Metal compute shader**, with an Accelerate/CPU fallback used in tests. Target under 15 s for 30 frames at 4096 × 2048 on an iPhone 13 or newer. Report progress (0–1) and support cancellation.
8. **Output.**
   - JPEG with **GPano XMP metadata**: `ProjectionType=equirectangular`, `FullPanoWidthPixels`, `FullPanoHeightPixels`, `CroppedAreaImageWidthPixels`, `CroppedAreaImageHeightPixels`, `CroppedAreaLeftPixels=0`, `CroppedAreaTopPixels=0`, and `PoseHeadingDegrees` when the heading is known. Photos apps then recognise it as a 360° photo.
   - Save it to Photos as well.

## 6. Milestone C: preview, hotspots, export

**Viewer.** A sphere with inward-facing normals and the panorama as an unlit texture, with the camera at the centre. Drag to look around, pinch to zoom (FOV 40–100°), and a "gyro" toggle that uses CoreMotion attitude (magic window). Pitch is clamped to ±85°. The initial view faces yaw 0.

**Hotspot editor.**
- Tap the panorama to drop a dot at that yaw/pitch (computed from the tap ray).
- Edit title (required), caption (required, max 300 chars), and optional `sources` (URLs).
- Drag to move, swipe to delete.
- Show the live yaw/pitch to one decimal.
- Warn when two dots are closer than 12°.
- Hotspots render as small white dots with a soft dark halo.

**Export.** A "MIRAS package" folder, also shareable as a `.zip` through the share sheet and Files:
```
<slug>/
  panorama.jpg            equirectangular, GPano XMP
  capture.json            app version, device model, date, frame count, output size,
                          yawReference, heading + accuracy, GPS (lat, lon, accuracy),
                          stitch settings, coverage %, warnings
  hotspots.json           exact MIRAS format, see below
  frames/                 optional (setting): raw frames + frames.json for re-stitching
```
`hotspots.json` must match the MIRAS viewer format exactly:
```json
{
  "defaults": { "triggerAngle": 8, "exitAngle": 11, "hoverAngle": 3, "hoverExitAngle": 4.5,
                "dwellTime": 700, "duration": 8000, "cooldown": 4000 },
  "hotspots": [
    { "id": "kebab-case-unique", "view": "<slug>", "title": "…", "yaw": 0, "pitch": 0,
      "caption": "…", "sources": [] }
  ]
}
```
Use `yaw` in the range 0…360, rounded to 1 decimal.

**Library screen.** A list of captures with a thumbnail, date, place name (reverse geocode), and status: frames only / stitched / tagged. Actions: open, re-stitch, export, delete (with confirmation).

## 7. Testing you must run yourself (no device needed)

1. **Unit tests (XCTest)** for all of `Geometry`: conversions and their inverses, wrap-around, poles, the `ShotPlanner` coverage test, and true-north conversion.
2. **Stitcher self-test with synthetic frames.** This is required.
   - Load the bundled `MIRAS_VR_Test_Panorama.png` (2:1). If it is missing, generate a procedural test panorama with a labelled yaw/pitch grid.
   - Render virtual camera frames from it at every `ShotPlanner` target, using realistic intrinsics (1920 × 1440, about 63° vertical FOV). Add small random orientation noise (±0.5°) and per-frame gain differences (±15%).
   - Stitch those frames with `StitchService` (CPU path in tests) and compare with the source panorama, excluding |pitch| > 80°.
   - Assert: mean absolute error < 0.06 (0–1 scale), no horizontal offset beyond 2 px at 2048 width (find the best circular shift), no seam at u = 0/1, and coverage ≥ 98% excluding the nadir cap.
3. **Hotspot export test.** Write a package, read `hotspots.json` back, validate the schema, and check yaw/pitch round-trip through the tap-ray math.
4. Build for the simulator with `xcodebuild -scheme MIRASCapture -destination 'platform=iOS Simulator,name=iPhone 15' build test`. Fix every warning you reasonably can, and all errors.

Add a hidden **Debug menu** (long-press the app title):
- "Run synthetic stitch test" shows the result image and metrics on device.
- "Load sample capture" lets the preview, tagging and export screens be tried in the simulator.

## 8. UI and design

- Calm, premium, museum-like. Dark UI with a warm accent (`#E0893A`), SF Pro, generous spacing, large tap targets, VoiceOver labels on every control, Dynamic Type support.
- **Onboarding:** three short screens.
  1. "Stand in one spot."
  2. "Turn around your phone, not your body."
  3. "Follow the dots."

  Then the camera and location permission prompts, each with a one-line reason.
- The capture screen has minimal chrome: a close button, progress, coaching banners and finish.
- Every error has a clear message and a recovery action. No silent failures.

## 9. Deliverables and report

- `project.yml`, all Swift and Metal sources, tests, an asset catalog with a simple placeholder app icon, and `README.md` covering:
  - setup (XcodeGen, signing team, running on a device)
  - architecture diagram (text)
  - capture tips
  - the MIRAS package format
  - known limitations: parallax near the camera, moving people ghosting, nadir, no 360° video
- At the end, report:
  - what you built
  - the exact test results (paste the `xcodebuild test` summary and the synthetic stitch metrics)
  - what still needs on-device verification: ARKit tracking, the high-resolution capture path, exposure lock, Metal performance, the gyro viewer
  - a prioritised list of next steps

## 10. Working rules

- Plan briefly, then implement milestone A → B → C in order. Commit or checkpoint after each milestone.
- After each milestone, build and run the tests. Never claim something works without running it. Be explicit about what was verified in the simulator and what needs a real iPhone.
- Prefer simple, readable code with small files. Add brief comments only where the math or an Apple API behaviour is non-obvious.
- If an API behaves differently than expected (for example, high-res capture unavailable), implement the fallback, note it in the README, and continue. Don't stall.
