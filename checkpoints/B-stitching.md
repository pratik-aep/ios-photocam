# Milestone B checkpoint

Implemented shared CPU reprojection, Metal compute kernel, least-squares overlap gains, bounded NCC rotation refinement, hole fill with Accelerate blur, GPano XMP JPEG output, Photos saving and background work with progress/cancellation.

Labelled synthetic source is bundled. Virtual frames are rendered at 1920 × 1440 with 63° vertical FOV, deterministic ±0.5° pose noise and ±15% gains. CPU output at 2048 × 1024: MAE 0.01836, best horizontal shift 1 pixel, seam excess discontinuity 0.00689, coverage 100%. Exact wrap-boundary rays also agree. Metal ran on this Mac and agrees with the CPU output within 0.002 mean normalized channel error. Saved camera records were also stitched through the complete image decode/pose transform path, including a north offset.

The iPhone 13 15-second performance target is not measured. Simulator execution and real-device verification remain outstanding.
