# Issue 446 recovery checkpoint

This is work in progress, saved from the rental Mac at the user’s request. It is not a release or a claim of frame-perfect playback. No issue, PR, or comment was created.

The Apple change renders ASS against actual decoded source frame timestamps, schedules transparent subtitle buffers on the video presentation timebase, gates initial playback on font and raster readiness, and preserves matching video/subtitle images during transport changes. The Aether changes expose displayed software pixels and timestamps through IOSurface identity and fix paused seek admission. Native AVPlayer uses separate outputs for current-frame reads and future-frame warming.

## Required dependency patch

The Apple sources require the APIs in `aether-engine.patch`. Apply it to AetherEngine at `ec969b734548d09f8324dc18645050cdc94d3018` before building. The rental’s shared checkout is `/Users/m1/silo-446-build/SourcePackages/checkouts/AetherEngine`; Xcode builds use `-clonedSourcePackagesDirPath /Users/m1/silo-446-build/SourcePackages -disableAutomaticPackageResolution`. A clean upstream dependency alone is insufficient. No package pin or signing configuration was changed.

## Recovery harness

The two Swift harnesses and Python/Vision analysis tools are recovery copies. They run in a separate scratch checkout, not in the production app. Update paths and simulator IDs for another host. The scratch app host displays a blank view under XCTest; macOS uses `OpticalMacHarness` only with `-optical446`. Add synthetic files to the scratch test resources and copy production player/subtitle sources from this branch. Native tests serve `fixtures/hls/media.m3u8` on localhost port 8446 and assert `remoteBypass`; MKV tests assert `software`. Generate HLS and MKV from `fixtures/sync.mp4` with FFmpeg, attaching `sync.ass` or `animated.ass` with stream copy. `prepare-fixtures.py` also regenerates the source video; its original header is included as `fixtures/original.ass`. The Vision helper builds with `swiftc ocr-frames.swift -o ocr-frames`; Python requires NumPy and Pillow. Analysis expects `ffmpeg-path.txt` beside the scripts.

The 24 fps source video burns each frame number and timestamp into the image. Static SYNC changes at whole seconds; the animated vector moves 800 source pixels per second. Software MKV timestamps have a measured 21 ms offset; native HLS uses zero. The analyzer compares subtitle phase to the visible source frame, not wall clock. OCR can misread counters: inspect every flagged group against the original full-resolution frame before assigning a result. Headers describe requested actions and may precede their applied state during a paused preparation gate.

## Validation status at this checkpoint

This second checkpoint includes candidate 41. Its new native lookahead reset and speed-change gate still need optical validation.

- iOS focused renderer/presentation tests: 24 passed on candidate 38.
- iOS software candidate 38 and native AVPlayer (`remoteBypass`) candidate 39: first cue appears on source frame 48, with no subtitle visible before that frame. Animation phase has no mismatches in the onset and sampled pause/resume and seek captures. Pixel-position tolerance is four source pixels; frame counters establish the timing oracle.
- Full iOS/tvOS optical harness executions have passed through candidate 40b. Harness assertions verify route and transport state; quantitative frame analysis remains required.
- Later delay, speed, and track-change captures still include failures and pending-state transients. Candidate 41 resets the native future-frame reader when playback is prepared again and gates speed changes. Do not report frame-perfect playback yet.
- macOS software, native AVPlayer (`remoteBypass`), and native loopback have played controlled fixtures through native computer use. Final-source repeats remain pending.
- Final real server playback, final focused tests, SSA coverage, and unsigned physical-device IPA builds remain pending. Physical-device playback is untested. Earlier IPAs are obsolete.

Recordings, screenshots, detailed frame CSVs, private logs, and build outputs remain outside Git at `/Users/m1/silo-446-build/validation-20261003-032038`. This checkpoint backs up implementation, synthetic test inputs, and recovery tools to the fork. It does not upload recordings or IPAs; those require a separate off-device transfer. The parallel Vision helper builds with `swiftc -O ocr-frames-parallel.swift -o ocr-frames-parallel`. `source-identity.json` records the pre-checkpoint base and exact changed file hashes. Subsequent results must identify subsequent source changes.
