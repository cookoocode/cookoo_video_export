library;

import 'dart:ui' as ui;
import 'package:flutter/services.dart';

/// Container/codec support is discovered per device, not inferred from OS.
enum VideoCodec { h264, hevc, prores422, prores4444 }

class VideoExportException implements Exception {
  const VideoExportException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'VideoExportException($code): $message';
}

class VideoSpec {
  const VideoSpec(
      {required this.codec,
      required this.width,
      required this.height,
      required this.fpsNumerator,
      this.fpsDenominator = 1,
      required this.bitrate,
      required this.outputPath});
  final VideoCodec codec;
  final int width, height, fpsNumerator, fpsDenominator, bitrate;
  final String outputPath;
  double get fps => fpsNumerator / fpsDenominator;
  void validate() {
    if (width <= 0 ||
        height <= 0 ||
        width.isOdd ||
        height.isOdd ||
        fpsNumerator <= 0 ||
        fpsNumerator > 1000000 ||
        fpsDenominator <= 0 ||
        bitrate < 0 ||
        outputPath.isEmpty) {
      throw const VideoExportException('invalid_arguments',
          'Invalid video dimensions, frame rate or output path.');
    }
  }

  Map<String, Object> toMap() => {
        'codec': codec.name,
        'width': width,
        'height': height,
        'fpsNum': fpsNumerator,
        'fpsDen': fpsDenominator,
        'bitrate': bitrate,
        'path': outputPath
      };
}

class VideoCapabilities {
  const VideoCapabilities(this.maxEdge, {this.maxEdgeAt60, this.freeBytes});
  final Map<VideoCodec, int> maxEdge;
  final Map<VideoCodec, int>? maxEdgeAt60;
  final int? freeBytes;
}

class VideoFile {
  const VideoFile(this.path, this.bytes);
  final String path;
  final int bytes;
}

/// Encodes one frame at a time. Await each append to bound native memory.
class VideoEncoder {
  const VideoEncoder();
  static const channel = MethodChannel('cookoo_video_export/encoder');
  Future<VideoCapabilities> capabilities() async {
    try {
      final raw =
          await _invoke<Map<Object?, Object?>>('capabilities', const {});
      Map<VideoCodec, int> codecs(Object? value) => {
            for (final codec in VideoCodec.values)
              if (value is Map && value[codec.name] is int)
                codec: value[codec.name] as int,
          };
      return VideoCapabilities(codecs(raw?['codecs']),
          freeBytes: raw?['freeBytes'] as int?,
          maxEdgeAt60:
              raw?['codecs60'] == null ? null : codecs(raw?['codecs60']));
    } on MissingPluginException {
      return const VideoCapabilities({});
    }
  }

  /// Checks the actual requested dimensions and rate on the platform.
  Future<bool> supports(VideoSpec spec) async {
    spec.validate();
    return await _invoke<bool>('supports', spec.toMap()) ?? false;
  }

  Future<VideoSession> start(VideoSpec spec) async {
    spec.validate();
    final id = await _invoke<int>('start', spec.toMap());
    if (id == null) {
      throw const VideoExportException(
          'failed', 'No encoding session returned.');
    }
    return VideoSession._(id, spec);
  }
}

class VideoSession {
  VideoSession._(this._id, this.spec);
  final int _id;
  final VideoSpec spec;
  bool _closed = false;
  bool _busy = false;
  int? _lastIndex;
  void _open() {
    if (_closed || _busy) {
      throw StateError('Session is closed or an operation is already pending.');
    }
  }

  /// The caller retains ownership of [image] and must dispose it.
  Future<void> append(ui.Image image, int index) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw const VideoExportException('failed', 'Frame readback failed.');
    }
    await appendRgba(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), index,
        width: image.width, height: image.height);
  }

  Future<void> appendRgba(Uint8List rgba, int index,
      {required int width, required int height}) async {
    _open();
    if ((_lastIndex == null && index != 0) ||
        index < 0 ||
        (_lastIndex != null && index != _lastIndex! + 1) ||
        width != spec.width ||
        height != spec.height ||
        rgba.length != width * height * 4) {
      throw const VideoExportException('invalid_arguments',
          'Frame dimensions or sequence do not match the session.');
    }
    _busy = true;
    try {
      await _invoke<void>('append', {
        'id': _id,
        'frame': index,
        'width': width,
        'height': height,
        'rgba': rgba
      });
      _lastIndex = index;
    } finally {
      _busy = false;
    }
  }

  Future<VideoFile> finish() async {
    _open();
    if (_lastIndex == null) {
      throw const VideoExportException(
          'invalid_arguments', 'No frames were submitted.');
    }
    _busy = true;
    try {
      final out = await _invoke<Map<Object?, Object?>>('finish', {'id': _id});
      _closed = true;
      return VideoFile(out!['path'] as String, out['bytes'] as int);
    } finally {
      _busy = false;
    }
  }

  /// Idempotent. Native cancellation removes partial output.
  Future<void> cancel() async {
    if (_closed) return;
    await _invoke<void>('cancel', {'id': _id});
    _closed = true;
  }
}

/// A cancellable file-to-file audio operation. The video track is copied.
class AudioMux {
  AudioMux(
      {required this.videoPath,
      required this.audioPath,
      required this.outputPath,
      this.loop = true,
      this.fadeOut = const Duration(seconds: 1)});
  final String videoPath, audioPath, outputPath;
  final bool loop;
  final Duration fadeOut;
  static int _nextId = 0;
  final int _id = ++_nextId;
  bool _cancelled = false;
  bool _started = false;
  Future<VideoFile> run() async {
    if (_cancelled) {
      throw const VideoExportException('cancelled', 'Audio mux cancelled.');
    }
    if (_started) throw StateError('Audio mux has already started.');
    if (videoPath.isEmpty ||
        audioPath.isEmpty ||
        outputPath.isEmpty ||
        outputPath == videoPath ||
        outputPath == audioPath ||
        fadeOut.isNegative) {
      throw const VideoExportException(
          'invalid_arguments', 'Invalid audio paths or fade duration.');
    }
    _started = true;
    final raw = await _invoke<Map<Object?, Object?>>('muxAudio', {
      'id': _id,
      'videoPath': videoPath,
      'audioPath': audioPath,
      'path': outputPath,
      'loop': loop,
      'fadeOutUs': fadeOut.inMicroseconds,
    });
    return VideoFile(raw!['path'] as String, raw['bytes'] as int);
  }

  Future<void> cancel() async {
    _cancelled = true;
    await _invoke<void>('cancelAudio', {'id': _id});
  }
}

Future<T?> _invoke<T>(String method, Map<String, Object?> args) async {
  try {
    return await VideoEncoder.channel.invokeMethod<T>(method, args);
  } on PlatformException catch (e) {
    throw VideoExportException(e.code, e.message ?? 'Video export failed.');
  }
}
