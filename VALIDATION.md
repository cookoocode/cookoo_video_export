# Local validation — 2026-10-18

## Native encoder and audio mux

Tested on a physical Samsung SM-S901U and an iPad Pro 11-inch (M5) simulator:

- Encode 61 H.264 frames at 640 × 360 and 30000/1001 fps. The odd frame count
  deliberately makes the duration fractional in milliseconds.
- Mix a 0.25-second WAV into the video, looping it and fading the last second.
- Decode every frame with an independent decoder (external ffmpeg, QA only).
- Verify both reported frame rates remain 30000/1001 and all 61 frames survive.
- Verify video and AAC audio duration is approximately 2.035367 seconds, audio is stereo 48 kHz,
  and the audio amplitude falls during the final fade.
- Compare SHA-256 hashes of the compressed video track before and after muxing:
  identical on both platforms.
- Cancel an encoding session and verify the partial file is removed.

The physical Samsung also encoded and fully decoded six-frame probes at
1920 × 1080 / 30 fps, 1920 × 1080 / 60 fps, and 3840 × 2160 / 30 fps.
These short probes establish codec/configuration compatibility, not sustained
4K performance, thermal behavior or battery use.

The reproducible test is `example/integration_test/encoder_smoke_test.dart`.
Capture its output and run `tool/validate_smoke.py` as described in the README.
Local media and machine-readable reports are under `build/validation/` and are
generated artifacts rather than package source.

## App integration

TextCrawl uses the shared native encoder and audio mux from its production export
provider. Its frame-source tests verify all three output shapes, deterministic
frames and the free end card. LastReel's native adapter tests preserve rational
frame rates, capability limits and its existing error types. LastReel retains
its browser renderer and PNG sequence export outside this plugin.

Both apps built for Android and the iOS simulator. Plugin contract tests and
both apps' focused export test suites passed.

TextCrawl's `integration_test/native_export_test.dart` also passed on the physical
Samsung in a separate QA installation. Its actual frame renderer produced a
complete 19.766667-second 1280 × 720 / 30 fps crawl (593 frames), mixed looping
music, painted the free end card, and saved the result to the gallery. The cancellation test
verified that the job's work directory was removed. Independent decoding and
stream inspection confirmed all frames, stereo 48 kHz AAC and matching durations.

Permission denial, background/resume and longer exports still require
app-level device QA. The short successful export does not
establish thermal performance or the complete lifecycle matrix.

LastReel/Endcrawl's real `FrameRenderer`, shared encoder adapter and gallery
destination also passed on the Samsung in `com.lastreel.app.exporttest`:

- H.264: 1280 × 720, 180 decoded frames, exactly 30 fps, 6 seconds.
- HEVC: 1280 × 720, 91 decoded frames, exactly 30000/1001 fps, 3.036367 seconds.
- Both files were confirmed in Android's media library and decoded fully with
  an independent decoder. Cancellation removed its partial native file.
- Cold font loading exposed an offscreen-tree rebuild race. LastReel now loads
  its credit font weights before attaching the render tree and keeps the subtree
  stable while measuring it. Its ten renderer tests passed after the fix.

The existing `com.lastreel.app` installation was neither cleared nor replaced;
its version and installation timestamps were unchanged after the device tests.

## App 1080p and 4K exports on the physical Samsung

Both app integration tests passed at 1920 × 1080 and 3840 × 2160 on the same
SM-S901U, using fresh isolated test package IDs. No existing app was cleared,
uninstalled or replaced. Version and installation timestamps of both original
apps and both previously installed Export QA apps were unchanged afterward.

| App | Codec | Resolutions | Frames | Frame rate | Duration |
| --- | --- | --- | --- | --- | --- |
| TextCrawl | H.264 + AAC | 1080p, 4K | 593 each | 30 | 19.766667 s |
| Endcrawl / LastReel | H.264 | 1080p, 4K | 180 each | 30 | 6 s |
| Endcrawl / LastReel | HEVC | 1080p, 4K | 91 each | 30000/1001 | 3.036367 s |

All six exports were confirmed in Android MediaStore. Independent stream
inspection verified the exact dimensions, frame counts and both reported frame
rates. Every frame decoded successfully. TextCrawl's stereo 48 kHz AAC matched
video duration within 1 ms at both resolutions; its actual crawl and free end
card were inspected visually. Endcrawl rendered its actual credit blocks.
All six gallery files also opened and displayed video in Samsung's native video
player; playback screenshots were checked on the connected phone.

The integration tests accept `EXPORT_RESOLUTION_ONLY=true`, plus
`EXPORT_QUALITY=p1080` / `uhd4k` for TextCrawl or `EXPORT_EDGE=1920` / `3840`
for Endcrawl. Pass these with `--dart-define` to the device test command.
Always use a fresh application ID: Flutter's integration test runner removes
its test installation. Generated MP4 files, extracted frames and JSON reports
are under each app's `build/export-device-validation/1080/` and `4k/` directories.

These complete short exports validate the app pipelines at both resolutions;
they do not establish performance or thermal behavior for long projects.

## App 1080p and 4K exports on the iPad simulator

The same six-case matrix above passed on the iPad Pro 11-inch (M5), iOS 26.5
simulator. Both apps used fresh test bundle identifiers. The existing TextCrawl
installation retained its original bundle/data container paths and version;
SHA-256 fingerprints of its Documents and Library/Preferences files were
unchanged after all tests. No existing app data or Photos assets were cleared.

- TextCrawl: 593 H.264 frames at exactly 30 fps, 19.766667 seconds, stereo
  48 kHz AAC with matching duration, at both 1920 × 1080 and 3840 × 2160.
- Endcrawl: 180 H.264 frames at exactly 30 fps / 6 seconds, and 91 HEVC frames
  at exactly 30000/1001 fps / 3.036367 seconds, at both resolutions.
- Every exported frame decoded successfully. All six successful MP4s matched
  their saved Photos originals byte for byte. Extracted credit/end-card frames
  were inspected. Generated files and JSON reports are in each app's
  `build/export-ipad-validation/1080/` and `4k/` directories.

The first TextCrawl run exposed an integer-frame-rate music mux issue:
AVFoundation changed the video track time base from 30 to 600 ticks/second,
so the existing timing repair skipped a stretched final decode sample. The
shared iOS muxer now converts the original CFR sample duration exactly into
the output track's time base before repairing the final sample. TextCrawl
was rerun successfully at both resolutions after this fix. Run
`python3 tool/test_ios_video_timing.py` on macOS for eight regression cases
against the production Swift timing repair, including time-base conversion,
NTSC timing and unchanged handling of VFR/mismatched inputs. Simulator results
do not establish physical iPad hardware performance.
