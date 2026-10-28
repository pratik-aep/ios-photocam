# MIRAS Capture verification report

Latest: [stitch quality checkpoint](checkpoints/E-stitch-quality.md), 28 October 2026, Xcode 27.1. The suite passes **33 tests** with `swift test -c release` on macOS and with `xcodebuild test` on the iOS 27.1 simulator (iPhone 18 Pro Max), including the Metal/CPU agreement test. The unsigned generic iOS device build and build-for-testing succeed without Swift warnings. This resolves the simulator and Metal toolchain blockers described in the [core debugging checkpoint](checkpoints/D-core-debugging.md) and below. Real-iPhone capture, performance and memory remain unverified. The historical verification below used Xcode 26.3.

Verified in this project folder on 28 October 2026 with Xcode 26.3 (17C529) and Apple Swift 6.2.4, using Swift 5.9 language mode for the iOS project. XcodeGen 2.46.0 and Apple's Metal toolchain were installed during implementation.

## What was built

The project contains guided AR capture and coaching, computed shot planning, heading/location, per-frame image/pose persistence, CPU and Metal stitching, overlap exposure gains, optional bounded rotation refinement, hole fill and MIRAS nadir cap, GPano JPEG output, Photos saving, panorama drag/pinch/gyro viewing, hotspot authoring, library management, standard ZIP export and simulator-oriented debug sample tools. `project.yml` generates the project; no project file was hand-written. Milestone checkpoints are retained in `checkpoints/`.

## Executed tests: macOS, shared production code

Command:

```sh
swift test -c release
```

Exact final XCTest summary:

```text
Test Suite 'All tests' passed at 2026-10-28 06:03:04.894.
     Executed 13 tests, with 0 failures (0 unexpected) in 6.657 (6.659) seconds
SYNTHETIC 2048: MAE 0.01836 · shift 1 px · seam 0.00689 · coverage 100.00%
```

The timestamp above is retained verbatim from the command output. The synthetic fixture renders the bundled labelled 2:1 panorama into 1920×1440 frames at every planned target with 63° vertical FOV, deterministic ±0.5° orientation noise and ±15% exposure differences. Stitch output is 2048×1024. Metrics exclude |pitch| > 80°. MAE must be below 0.06, horizontal displacement no more than 2 pixels, seam excess discontinuity below 0.02, and coverage at least 98%. Exact ±180° rays are compared separately to verify periodicity independently of local image contrast.

Tests exercised:

- Yaw/pitch, vector, UV and pixel inverses, poles, wrap and true-north fallback.
- A 10,000-direction spherical coverage test using planned camera fields of view and an edge margin.
- Tap-ray direction calculation.
- Full synthetic reconstruction at 2048 width.
- Actual Metal execution versus the CPU implementation; normalized mean channel error below 0.002. This ran on the Mac GPU, not an iPhone GPU.
- CPU service execution and cancellation.
- Stored JPEG/pose/intrinsics reprojection through StitchService with a 37° north reference offset.
- Missing-nadir filling, opaque output, optional logo cap, and preservation of covered horizon pixels.
- GPano XMP metadata read back through ImageIO.
- Exported hotspot keys/defaults, URL validation, one-decimal yaw wrap, and tap-ray round trip.
- Archive CRC/integrity checked by `/usr/bin/unzip -t`, with exact ZIP paths checked separately.
- SceneKit rendered texture coordinates compared with tap rays at three view directions and three screen positions, including pitch and longitude changes. This found and fixed an initial upside-down texture mapping.

Full output: `checkpoints/all-tests.log`. After removing an unnecessary isolation modifier from ImageCodec, the iOS compile/link check and GPano metadata test were repeated successfully (`checkpoints/final-codec-check.log`).

## iOS compilation and link verification

A direct Xcode target build avoids simulator destination selection and can compile against the installed simulator SDK even without a runtime:

```sh
xcodebuild -project MIRASCapture.xcodeproj -target MIRASCaptureTests \
  -sdk iphonesimulator ARCHS=arm64 \
  EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets \
  SYMROOT="$PWD/DerivedData/FinalBuildProducts" \
  OBJROOT="$PWD/DerivedData/FinalBuildIntermediates" \
  CODE_SIGNING_ALLOWED=NO build
```

Result: `** BUILD SUCCEEDED **`. The app, Geometry framework, Metal shader/default library, and iOS XCTest bundle compile and link. **Only the asset catalog is excluded for this verification command.** This is a compile check, not a simulator test pass or a distributable release build. Asset exclusion is a command-line override; the normal project still includes its app icon and accent color. Info.plist syntax and the 1024×1024 icon dimensions were separately verified.

Output: `checkpoints/build-with-metal.log`. Xcode emits its framework-independent warning that AppIntents metadata extraction was skipped because the project does not use AppIntents. There are no Swift source warnings in the final compile check.

## Full simulator build/test: blocked by environment

The requested command was attempted with a one-second destination timeout:

```sh
xcodebuild -scheme MIRASCapture \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -destination-timeout 1 build test
```

Exact diagnostic:

```text
xcodebuild: error: Unable to find a device matching the provided destination specifier:
        { platform:iOS Simulator, OS:latest, name:iPhone 15 }

The requested device could not be found because no available devices matched the request.
```

`xcrun simctl list runtimes` returns no installed runtimes. A normal direct build also fails inside Apple's asset compiler with:

```text
Assets.xcassets: error: No available simulator runtimes for platform iphonesimulator.
SimServiceContext supportedRuntimes=[]
```

Consequently **there is no `xcodebuild test` success summary**, and no full simulator UI walkthrough was completed. The iOS runtime download was attempted; an 8.39 GB download is required. At verification wrap-up, the runtime download remained active (about 21% complete) in the launched `xcodebuild -downloadPlatform iOS` process. Its progress is recorded in `checkpoints/runtime-download.log`. Install the runtime from Xcode > Settings > Components, create/select an available iPhone simulator, regenerate the project, and rerun the normal build/test command. The Metal compiler was successfully installed and is no longer a build blocker.

Diagnostics: `checkpoints/xcodebuild-test.log`, `checkpoints/build-full.log`.

## Required real-iPhone verification

ARKit normal/limited tracking behavior and recovery; portrait target projection; high-resolution capture/fallback; exact exposure/white-balance/focus locks; steadiness and retake timing; haptic feedback; true-north alignment and heading reliability; Photos permission flow and saved GPano recognition; CoreMotion magic-window direction; GPU memory use, cancellation latency and thermal behavior. The 4096×2048 under-15-second iPhone 13 performance target has not been measured.

## Prioritized next steps

1. Install an iOS Simulator runtime and run the full Xcode build/test plus onboarding, sample preview, hotspot editing and Files export walkthrough. Validate Dynamic Type and VoiceOver.
2. Sign and run on a real iPhone. Verify capture alignment/roll, exposure locks, high-resolution fallback, heading and gyro behavior with a known north-facing scene.
3. Benchmark 40-shot 4096×2048 stitching and peak memory on iPhone 13; tune decoded-frame size and the conservative planner from those measurements.
4. Evaluate real heritage scenes with foreground parallax, moving people, lighting changes and missing nadir; replace the placeholder branding for distribution.
