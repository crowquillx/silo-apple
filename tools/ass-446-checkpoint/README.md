# Issue 446 recovery checkpoint

The branch is rebased onto upstream main `8be2542dede46a7ae2cbc89777cda002b3f92c42`. The Apple renderer now pairs each ASS/SSA raster with its exact decoded video frame and queues one composed pixel buffer on the playback timebase. This removes the separate-layer phase errors preserved in the earlier checkpoints. AVPlayer still supplies native decoding, audio and the clock on native routes; its original AVPlayerLayer is covered by the paired display while authored subtitles are selected.

## Required dependency patch

Silo pins the official `https://github.com/Silo-Server/AetherEngine` repository at `b1e4879e6a41477ebef3b68e8d9f65239d1ba80b`. Our additional changes are local and are not part of that upstream commit. Apply `aether-engine.patch` to a clean checkout at that revision before building this branch. No dependency pin or signing configuration was changed.

The patch exposes displayed software pixels and frame identity, retains queued pixels while a frame observer is attached, and fixes paused seek admission/preroll. It also allows the Apple client's explicit 60-second font request to wait for response headers; ordinary requests retain their existing timeout. Frame retention clears on flush, selection teardown and stop, and is trimmed behind the playhead. The rental builds use `/Users/m1/silo-446-build/SourcePackagesRebased` with `-disableAutomaticPackageResolution`.

## Measured validation

The rebased paired renderer completed software and native remote-HLS playback on iOS 27 and tvOS 27. Across 24 short clips, 10,665 evaluated captured frames had zero measured animation-phase mismatches or missing expected cues after controls applied. The first cue is absent on source frame 47 and present on frame 48 on all four routes. Vector phase error remained within 2.75 ms of source time, below the 41.7 ms source-frame interval. Alternate-track static color checks also had zero mismatches.

The sequences cover pause/resume, forward/backward/repeated seeks, positive/negative subtitle delay, 1.5x/0.5x speed, off/on, track changes, item replacement, resizing and a longer drift interval. Control preparation intervals remain in the raw clips and CSVs as `pending`; they are not counted as applied playback. Applied state is determined from engine playback-clock progress independently of subtitle pixels.

All 29 focused renderer, presentation, composition and failure-display tests passed on each simulator. The compositor tests verify SDR placement and preservation of 10-bit PQ metadata and highlight values. The failure test verifies that a font error hides the opaque paired picture while the engine clock continues. Short final-source SSA and 60 fps optical repeats supplement the full sequences; their results are in the external report.

The rebased macOS build passed. Native computer use confirmed software, native remote HLS (`remoteBypass`) and native loopback playback, with matching static subtitles after paused seeks; positive delay selected the preceding cue on a held software frame. These manual checks do not establish frame-perfect animated playback on macOS. Both simulators rejected hardware decode for the loopback fixture and fell back to software, so native loopback is untested there.

Finite simulator captures establish the observed alignment, not a universal guarantee. Capture gaps limit smoothness measurements. Physical-device installation, display timing, HDR display output and native loopback animation remain untested. Final app/server checks, packaging status and exact artifact identity are recorded outside Git.

## Recovery harness and evidence

The Swift harnesses and Python/Vision analysis tools are recovery copies for a scratch checkout. Keep them out of production app targets. Update host paths and simulator IDs, copy this branch's player sources, and display a blank app view under XCTest. macOS uses `OpticalMacHarness` with `-optical446`. Native tests serve `fixtures/hls/media.m3u8` on localhost port 8446 and assert `remoteBypass`; software tests force and assert `software`. Loopback tests skip when the actual route differs.

The 24 fps source burns frame number and timestamp into the video. Static SYNC changes at whole seconds; the vector moves 800 source pixels per second. MKV timestamps have a measured 21 ms offset, while HLS uses zero. Generate HLS/MKV from `fixtures/sync.mp4` with FFmpeg and attach the supplied ASS/SSA fixtures. The Vision helper builds with `swiftc -O ocr-frames-parallel.swift -o ocr-frames-parallel`; Python analysis needs NumPy and Pillow. Set `ffmpeg-path.txt` beside the analysis scripts. Inspect flagged OCR groups against full-resolution frames before assigning failures.

Raw recordings, screenshots, CSVs, build/test logs, source snapshots and preserved failed experiments remain outside Git at `/Users/m1/silo-446-build/validation-20261003-032038` and `/Users/m1/silo-446-build/validation-20261003-154659`. The external results report identifies each build. `paired-video-prototype.patch` is a historical candidate-57 experiment relative to checkpoint `37335ffe`; it is superseded by the production sources in this branch and must not be reapplied. Earlier checkpoint branches preserve the failed separate-layer implementations.

No issue, pull request or comment was created. Checkpoint pushes save source and recovery inputs to the user's fork; recordings and IPAs need separate transfer off the rental. `rebased-source-identity.json` records the final changed-source hashes before the checkpoint commit.
