# cookoo_video_export

Flutter plugin shared by TextCrawl (starcrawler) and LastReel (endcrawl).
Extracted from COOKOO's Endcrawl encoder. Version 0.1.0 is distributed through
[GitHub](https://github.com/cookoocode/cookoo_video_export) and is not published
on pub.dev (`publish_to: none`).

Requires Flutter 3.44+ (Android build uses AGP 9 built-in Kotlin).

## Scope

- iOS 15+ and macOS 12+: a shared Darwin AVAssetWriter implementation, H.264/HEVC MP4 and device-supported ProRes MOV.
- Android 24+: MediaCodec/MediaMuxer, H.264/HEVC MP4.
- Sequential premultiplied RGBA frames with rational timestamps and bounded back-pressure.
- Device capabilities, exact requested-size/rate probe, storage capacity, typed failures and cancellation cleanup.
- Optional file-to-file audio muxing: audio trimmed or looped to video, AAC conversion, final fade. iOS also restores native CFR sample timing when AVFoundation passthrough stretches a B-frame tail. iOS uses AVFoundation; Android uses AndroidX Media3 Transformer 1.8.0 (Apache-2.0). The encoded video track is copied.
- CocoaPods and Swift Package Manager registration; neither app manually registers the encoder.

The package does not import app models, Riverpod, Firebase, ads, subscriptions, galleries or share UI. It does not record the screen. Callers own image rendering, progress, foreground/background policy and final file destinations. No network access or telemetry is performed by the encoder.

Web, PNG ZIP sequences, Windows and Linux are not implemented by this plugin. LastReel retains its existing browser and PNG implementations.

The Apple sources live in `darwin/`, registered with `sharedDarwinSource` for iOS and macOS. Only the Flutter framework import and registrar messenger access differ between those targets.

## Installation

Add the Git dependency to your app's `pubspec.yaml`:

```yaml
dependencies:
  cookoo_video_export:
    git:
      url: https://github.com/cookoocode/cookoo_video_export.git
      ref: main
```

Run `flutter pub get`. For reproducible app releases, replace `main` with a full
commit SHA and commit `pubspec.lock`. TextCrawl and LastReel pin the same revision;
neither needs a sibling package checkout or a vendored source copy.

## API

```dart
const encoder = VideoEncoder();
final spec = VideoSpec(
  codec: VideoCodec.h264, width: 1920, height: 1080,
  fpsNumerator: 30000, fpsDenominator: 1001,
  bitrate: 8000000, outputPath: '/absolute/path/video.mp4',
);
if (!await encoder.supports(spec)) return;
final session = await encoder.start(spec);
try {
  for (var index = 0; index < frameCount; index++) {
    final image = await renderFrame(index);
    try { await session.append(image, index); }
    finally { image.dispose(); }
  }
  final video = await session.finish();
} catch (_) {
  await session.cancel();
  rethrow;
}
```

Await every frame before sending the next. Frames must match the spec, use consecutive zero-based indices and be premultiplied RGBA. The caller retains ownership of `ui.Image`. `appendRgba` accepts tightly packed raw bytes. Inputs and outputs must be different files for `AudioMux`.

```dart
final mux = AudioMux(
  videoPath: video.path, audioPath: musicPath,
  outputPath: '/absolute/path/with-music.mp4',
  loop: true, fadeOut: const Duration(seconds: 1),
);
final result = await mux.run(); // mux.cancel() interrupts a pending operation
```

Keep the source video until audio processing succeeds. Budget disk space for both files. Gallery access and sharing belong to the app; the plugin returns a file and byte count. Finishing does not imply saving to Photos.

## Example and checks

`example/` exports procedural frames without either app's dependencies. Its device integration smoke test also generates a short WAV, loops/fades it into a two-second video, and checks cancellation removes partial files.

```sh
flutter test
cd example
flutter test integration_test/encoder_smoke_test.dart -d DEVICE_ID
```

Device smoke artifacts are printed as tagged base64 chunks, so Flutter's test-app cleanup does not lose the evidence. Capture test output to a log, then run `python3 tool/validate_smoke.py LOG build/validation/PLATFORM`. This external QA script requires ffprobe/ffmpeg; the plugin itself uses neither. It verifies exact frame rate/duration, full decoding, identical compressed video before/after audio, stereo 48 kHz AAC and the fade. Do not infer hardware 4K performance or ProRes support from a simulator. Mobile lifecycle and thermal testing must be performed on physical devices before release.

## Future publication

Choose/verify the public package name and confirm the licence. Review the platform support matrix, run both example builds and physical-device tests, then inspect `dart pub publish --dry-run`. Remove `publish_to: none` only when pub.dev publication is intended. The apps can then replace Git dependencies with the published version.
