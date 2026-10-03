# Issue 446 recovery checkpoint

This is work in progress, saved from the rental Mac at the user’s request. It is not a release or a claim of frame-perfect playback. No issue, PR, or comment was created.

The Apple change renders ASS against actual decoded source frame timestamps, schedules transparent subtitle buffers on the video presentation timebase, gates initial playback on font and raster readiness, and preserves matching video/subtitle images during transport changes. The Aether changes expose displayed software frame timestamps and fix paused seek admission.

## Required dependency patch

The Apple sources require the APIs in `aether-engine.patch`. Apply it to AetherEngine at `ec969b734548d09f8324dc18645050cdc94d3018` before building. The rental’s shared checkout is `/Users/m1/silo-446-build/SourcePackages/checkouts/AetherEngine`; Xcode builds use `-clonedSourcePackagesDirPath /Users/m1/silo-446-build/SourcePackages -disableAutomaticPackageResolution`. A clean upstream dependency alone is insufficient. No package pin or signing configuration was changed.

## Recovery harness

The two Swift harnesses and Python/Vision analysis tools are recovery copies. They run in a separate scratch checkout, not in the production app. Update paths and simulator IDs for another host. The scratch app host displays a blank view under XCTest; macOS uses `OpticalMacHarness` only with `-optical446`. Add synthetic files to the scratch test resources and copy production player/subtitle sources from this branch. Native tests serve `fixtures/hls/media.m3u8` on localhost port 8446 and assert `remoteBypass`; MKV tests assert `software`. Generate HLS and MKV from `fixtures/sync.mp4` with FFmpeg, attaching `sync.ass` or `animated.ass` with stream copy. `prepare-fixtures.py` also regenerates the source video; its original header is included as `fixtures/original.ass`. The Vision helper builds with `swiftc ocr-frames.swift -o ocr-frames`; Python requires NumPy and Pillow. Analysis expects `ffmpeg-path.txt` beside the scripts.

The 24 fps source video burns each frame number and timestamp into the image. Static SYNC changes at whole seconds; the animated vector moves 800 source pixels per second. Software MKV timestamps have a measured 21 ms offset; native HLS uses zero. The analyzer compares subtitle phase to the visible source frame, not wall clock. OCR can misread counters: inspect every flagged group against the original full-resolution frame before assigning a result. Headers describe requested actions and may precede their applied state during a paused preparation gate.

## Validation status at this checkpoint

- iOS focused renderer/presentation tests: 23 passed on candidate 34.
- iOS and tvOS software and native AVPlayer (`remoteBypass`) optical harness executions passed on candidate 35, including onset, controls, drift, and replacement. These assertions verify route and transport state, not every optical frame.
- Frame analysis still flags pause/resume, seek, speed, and pending track/delay changes. Some are pending-state or OCR artifacts; the remaining cases require correction and retesting. Do not report frame-perfect playback yet.
- Real server media was accessed earlier, but final source playback must be rechecked. Credentials and raw server data are excluded.
- macOS final route checks, native loopback, final focused tests, and unsigned physical-device IPA builds remain pending. Physical-device playback is untested. Earlier IPAs are obsolete.

Recordings, screenshots, detailed frame CSVs, private logs, and build outputs remain outside Git at `/Users/m1/silo-446-build/validation-20261003-032038`. This checkpoint backs up implementation, synthetic test inputs, and recovery tools to the fork. It does not upload recordings or IPAs; those require a separate off-device transfer. `source-identity.json` records the pre-checkpoint base and exact changed file hashes. Subsequent results must identify subsequent source changes.
