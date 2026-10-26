import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:cookoo_video_export/cookoo_video_export.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native frames and looping AAC produce real files', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Encoding smoke test'))),
    );
    final directory = await Directory.systemTemp.createTemp('cookoo-smoke-');
    final video = '${directory.path}/silent.mp4';
    const encoder = VideoEncoder();
    final spec = VideoSpec(
      codec: VideoCodec.h264,
      width: 640,
      height: 360,
      fpsNumerator: 30000,
      fpsDenominator: 1001,
      bitrate: 2000000,
      outputPath: video,
    );
    expect(await encoder.supports(spec), isTrue);
    final session = await encoder.start(spec);
    // An odd frame count makes the NTSC duration fractional in milliseconds,
    // catching audio muxers that accidentally round the final video sample.
    for (var i = 0; i < 61; i++) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawColor(Colors.black, BlendMode.src);
      canvas.drawRect(
        Rect.fromLTWH(i * 8, 80, 80, 180),
        Paint()..color = Colors.red,
      );
      canvas.drawRect(
        const Rect.fromLTWH(30, 30, 80, 20),
        Paint()..color = Colors.blue,
      );
      final picture = recorder.endRecording();
      final frame = await picture.toImage(640, 360);
      try {
        await session.append(frame, i);
      } finally {
        frame.dispose();
        picture.dispose();
      }
    }
    final silent = await session.finish();
    expect(silent.bytes, greaterThan(0));
    // 0.25 s of stereo PCM: the final file must loop it to video duration.
    const sampleRate = 48000, samples = sampleRate ~/ 4;
    final wav = ByteData(44 + samples * 4);
    void label(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        wav.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    label(0, 'RIFF');
    wav.setUint32(4, wav.lengthInBytes - 8, Endian.little);
    label(8, 'WAVE');
    label(12, 'fmt ');
    wav.setUint32(16, 16, Endian.little);
    wav.setUint16(20, 1, Endian.little);
    wav.setUint16(22, 2, Endian.little);
    wav.setUint32(24, sampleRate, Endian.little);
    wav.setUint32(28, sampleRate * 4, Endian.little);
    wav.setUint16(32, 4, Endian.little);
    wav.setUint16(34, 16, Endian.little);
    label(36, 'data');
    wav.setUint32(40, samples * 4, Endian.little);
    for (var i = 0; i < samples; i++) {
      final value = (math.sin(2 * math.pi * 440 * i / sampleRate) * 8000)
          .round();
      wav.setInt16(44 + i * 4, value, Endian.little);
      wav.setInt16(46 + i * 4, value, Endian.little);
    }
    final audio = File('${directory.path}/tone.wav');
    await audio.writeAsBytes(wav.buffer.asUint8List());
    final out = await AudioMux(
      videoPath: video,
      audioPath: audio.path,
      outputPath: '${directory.path}/mixed.mp4',
    ).run();
    expect(out.bytes, greaterThan(silent.bytes));
    final cancelledSpec = VideoSpec(
      codec: VideoCodec.h264,
      width: 640,
      height: 360,
      fpsNumerator: 30,
      bitrate: 2000000,
      outputPath: '${directory.path}/cancelled.mp4',
    );
    final cancelled = await encoder.start(cancelledSpec);
    await cancelled.cancel();
    expect(await File(cancelledSpec.outputPath).exists(), isFalse);
    // Local test artifacts are retained for ffprobe and full decoder checks.
    debugPrint('COOKOO_SMOKE_OUTPUT=${directory.path}');
    for (final name in ['silent.mp4', 'mixed.mp4']) {
      final encoded = base64Encode(
        await File('${directory.path}/$name').readAsBytes(),
      );
      for (var i = 0; i < encoded.length; i += 900) {
        debugPrintSynchronously(
          'COOKOO_ARTIFACT:$name:$i:${encoded.substring(i, math.min(i + 900, encoded.length))}',
        );
      }
    }
  });
  testWidgets('hardware HD, 60 fps and 4K configurations encode real frames', (
    tester,
  ) async {
    const encoder = VideoEncoder();
    final directory = await Directory.systemTemp.createTemp('cookoo-sizes-');
    for (final config in [
      (name: 'hd30', w: 1920, h: 1080, fps: 30),
      (name: 'hd60', w: 1920, h: 1080, fps: 60),
      (name: 'uhd30', w: 3840, h: 2160, fps: 30),
    ]) {
      final spec = VideoSpec(
        codec: VideoCodec.h264,
        width: config.w,
        height: config.h,
        fpsNumerator: config.fps,
        bitrate: 8000000,
        outputPath: '${directory.path}/${config.name}.mp4',
      );
      if (!await encoder.supports(spec)) {
        debugPrint('COOKOO_UNSUPPORTED=${config.name}');
        continue;
      }
      final session = await encoder.start(spec);
      try {
        for (var i = 0; i < 6; i++) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)
            ..drawColor(Colors.black, BlendMode.src);
          canvas.drawRect(
            Rect.fromLTWH(i * 100, 100, 150, 300),
            Paint()..color = Colors.green,
          );
          final picture = recorder.endRecording();
          final frame = await picture.toImage(config.w, config.h);
          try {
            await session.append(frame, i);
          } finally {
            frame.dispose();
            picture.dispose();
          }
        }
        final file = await session.finish();
        expect(file.bytes, greaterThan(0));
        final encoded = base64Encode(await File(file.path).readAsBytes());
        for (var i = 0; i < encoded.length; i += 900) {
          debugPrintSynchronously(
            'COOKOO_ARTIFACT:${config.name}.mp4:$i:${encoded.substring(i, math.min(i + 900, encoded.length))}',
          );
        }
      } catch (_) {
        await session.cancel();
        rethrow;
      }
    }
  });
}
