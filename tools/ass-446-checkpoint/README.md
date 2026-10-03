# Issue 446 recovery checkpoint

This is work in progress, saved from the rental Mac at the user’s request. It is not a release or a claim of frame-perfect playback. No issue, PR, or comment was created.

The Apple change renders ASS against actual decoded source frame timestamps, schedules transparent subtitle buffers on the video presentation timebase, gates initial playback on font and raster readiness, and preserves matching video/subtitle images during transport changes. The Aether changes expose displayed software pixels and timestamps through IOSurface identity and fix paused seek admission. Native AVPlayer uses separate outputs for current-frame reads and future-frame warming.

## Required dependency patch

The Apple sources require the APIs in `aether-engine.patch`. Apply it to AetherEngine at `ec969b734548d09f8324dc18645050cdc94d3018` before building. The rental’s shared checkout is `/Users/m1/silo-446-build/SourcePackages/checkouts/AetherEngine`; Xcode builds use `-clonedSourcePackagesDirPath /Users/m1/silo-446-build/SourcePackages -disableAutomaticPackageResolution`. A clean upstream dependency alone is insufficient. No package pin or signing configuration was changed.

## Recovery harness

The two Swift harnesses and Python/Vision analysis tools are recovery copies. They run in a separate scratch checkout, not in the production app. Update paths and simulator IDs for another host. The scratch app host displays a blank view under XCTest; macOS uses `OpticalMacHarness` only with `-optical446`. Add synthetic files to the scratch test resources and copy production player/subtitle sources from this branch. Native tests serve `fixtures/hls/media.m3u8` on localhost port 8446 and assert `remoteBypass`; MKV tests assert `software`. Generate HLS and MKV from `fixtures/sync.mp4` with FFmpeg, attaching `sync.ass` or `animated.ass` with stream copy. `prepare-fixtures.py` also regenerates the source video; its original header is included as `fixtures/original.ass`. The Vision helper builds with `swiftc ocr-frames.swift -o ocr-frames`; Python requires NumPy and Pillow. Analysis expects `ffmpeg-path.txt` beside the scripts.

The 24 fps source video burns each frame number and timestamp into the image. Static SYNC changes at whole seconds; the animated vector moves 800 source pixels per second. Software MKV timestamps have a measured 21 ms offset; native HLS uses zero. The analyzer compares subtitle phase to the visible source frame, not wall clock. OCR can misread counters: inspect every flagged group against the original full-resolution frame before assigning a result. Headers describe requested actions and may precede their applied state during a paused preparation gate.

## Validation status at this checkpoint

Candidate 43 preserves native decoder surfaces and maps the paused AVPlayerLayer image to its source timestamp. Raster preparation waits for that identity after native seeks. The dependency patch now includes the software seek preroll and font-request timeout changes that were previously present only on the rental Mac.

- iOS and tvOS focused renderer/presentation tests: 25 passed on each, including legacy SSA rendering at adjacent cue boundaries.
- macOS build passed. Native computer use confirmed static paused seeks on software, native HLS (`remoteBypass`), and native loopback. Positive subtitle delay also rendered the expected cue on a paused software frame. These manual checks do not establish frame-perfect animated playback.
- The earlier measured iOS software/native and tvOS software first cues appeared on source frame 48, with no cue visible earlier. The fresh candidate 42 native onset repeat also had no animation-phase mismatches.
- Candidate 43 still fails transport timing: iOS native repeated seek showed a one-source-frame lead across three captured frames; tvOS native forward seek showed a one-source-frame lag in one captured frame; tvOS software forward seek showed a one-source-frame lead across three captured frames. Frame-level CSVs and original captures preserve those failures.
- Delay, speed, and track-change captures also include pending-operation transients that need separate analysis against when the change takes effect. Do not report these cases as passed.
- AVPlayer preroll and moving the subtitle layer under the native video layer did not remove the transport errors. They remain scratch experiments outside this checkpoint. Further synchronized-layer experiments are also outside production source.
- The authenticated tvOS episode 11 run previously rendered its authored ASS track after the font-timeout fix. Final-source real-server playback and final iOS/tvOS optical validation remain pending.
- Unsigned IPAs remain deferred until the timing fix meets the user's frame-perfect target. Earlier IPAs are obsolete. Physical-device installation and playback are untested.

Recordings, screenshots, detailed frame CSVs, private logs, and build outputs remain outside Git at `/Users/m1/silo-446-build/validation-20261003-032038` and `/Users/m1/silo-446-build/validation-20261003-154659`. This checkpoint backs up implementation, synthetic test inputs, and recovery tools to the fork. It does not upload recordings or IPAs; those require a separate off-device transfer. The parallel Vision helper builds with `swiftc -O ocr-frames-parallel.swift -o ocr-frames-parallel`. `source-identity.json` records the pre-checkpoint base and exact changed file hashes. Subsequent results must identify subsequent source changes.
