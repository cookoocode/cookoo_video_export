import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cookoo_video_export/cookoo_video_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(VideoEncoder.channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'capabilities' => {
            'codecs': {'h264': 3840},
            'codecs60': {'h264': 1920},
            'freeBytes': 12345
          },
        'supports' => true,
        'start' => 1,
        'finish' || 'muxAudio' => {'path': '/output.mp4', 'bytes': 789},
        _ => null,
      };
    });
  });
  const spec = VideoSpec(
      codec: VideoCodec.h264,
      width: 4,
      height: 2,
      fpsNumerator: 30000,
      fpsDenominator: 1001,
      bitrate: 1000000,
      outputPath: '/output.mp4');
  test('capabilities preserve rate limits and actual settings are probed',
      () async {
    final caps = await const VideoEncoder().capabilities();
    expect(caps.maxEdge[VideoCodec.h264], 3840);
    expect(caps.maxEdgeAt60![VideoCodec.h264], 1920);
    expect(caps.freeBytes, 12345);
    expect(await const VideoEncoder().supports(spec), isTrue);
    expect(calls.last.arguments, spec.toMap());
  });
  test('exact timestamps, RGBA, and closed-session ownership', () async {
    final session = await const VideoEncoder().start(spec);
    expect(calls.first.arguments, spec.toMap());
    await session.appendRgba(Uint8List(32), 0, width: 4, height: 2);
    expect((calls.last.arguments as Map)['frame'], 0);
    await expectLater(session.appendRgba(Uint8List(32), 2, width: 4, height: 2),
        throwsA(isA<VideoExportException>()));
    await expectLater(session.appendRgba(Uint8List(16), 1, width: 4, height: 2),
        throwsA(isA<VideoExportException>()));
    await session.appendRgba(Uint8List(32), 1, width: 4, height: 2);
    final file = await session.finish();
    expect(file.bytes, 789);
    await expectLater(session.finish(), throwsStateError);
    await session.cancel();
    expect(calls.where((call) => call.method == 'cancel'), isEmpty);
  });
  test('invalid settings never reach native code', () async {
    await expectLater(
        const VideoEncoder().start(const VideoSpec(
            codec: VideoCodec.h264,
            width: 3,
            height: 2,
            fpsNumerator: 0,
            bitrate: 1,
            outputPath: '')),
        throwsA(isA<VideoExportException>()));
    expect(calls, isEmpty);
  });
  test('audio options and cancellation use an operation-specific id', () async {
    final mux = AudioMux(
        videoPath: '/video.mp4',
        audioPath: '/music.wav',
        outputPath: '/mix.mp4');
    await mux.run();
    final args = calls.last.arguments as Map;
    expect(args['loop'], isTrue);
    expect(args['fadeOutUs'], 1000000);
    await expectLater(mux.run(), throwsStateError);
    await mux.cancel();
    expect((calls.last.arguments as Map)['id'], args['id']);
    expect(calls.last.method, 'cancelAudio');
    await expectLater(mux.run(), throwsA(isA<VideoExportException>()));
  });
  test('audio cannot overwrite an input file', () async {
    await expectLater(
        AudioMux(
                videoPath: '/video.mp4',
                audioPath: '/music.wav',
                outputPath: '/video.mp4')
            .run(),
        throwsA(isA<VideoExportException>()));
    expect(calls, isEmpty);
  });
  test('native errors remain typed', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            VideoEncoder.channel,
            (_) async => throw PlatformException(
                code: 'out_of_space', message: 'Disk full'));
    await expectLater(
        const VideoEncoder().start(spec),
        throwsA(isA<VideoExportException>()
            .having((e) => e.code, 'code', 'out_of_space')));
  });
}
