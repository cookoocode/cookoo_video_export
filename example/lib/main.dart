import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:cookoo_video_export/cookoo_video_export.dart';

void main() => runApp(const MaterialApp(home: Example()));

/// A deliberately app-independent encoder sample: two seconds of moving bars.
class Example extends StatefulWidget {
  const Example({super.key});
  @override
  State<Example> createState() => _ExampleState();
}

class _ExampleState extends State<Example> {
  String status = 'Export a two-second 640 × 360 test video.';
  bool busy = false;
  Future<void> export() async {
    setState(() {
      busy = true;
      status = 'Encoding…';
    });
    VideoSession? session;
    try {
      final directory = await Directory.systemTemp.createTemp('cookoo-export-');
      const encoder = VideoEncoder();
      session = await encoder.start(
        VideoSpec(
          codec: VideoCodec.h264,
          width: 640,
          height: 360,
          fpsNumerator: 30,
          bitrate: 2000000,
          outputPath: '${directory.path}/example.mp4',
        ),
      );
      for (var i = 0; i < 60; i++) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..drawColor(Colors.black, BlendMode.src);
        canvas.drawRect(
          Rect.fromLTWH(i * 8, 100, 80, 160),
          Paint()..color = Colors.amber,
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
      final file = await session.finish();
      session = null;
      if (mounted) setState(() => status = '${file.path}\n${file.bytes} bytes');
    } catch (error) {
      if (mounted) setState(() => status = '$error');
    } finally {
      await session?.cancel();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Video encoder example')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          SelectableText(status),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: busy ? null : export,
            child: const Text('Export sample'),
          ),
        ],
      ),
    ),
  );
}
