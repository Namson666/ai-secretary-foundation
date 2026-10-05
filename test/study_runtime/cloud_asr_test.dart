import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_secretary/features/study_runtime/study_cloud_asr.dart';
import 'package:ai_secretary/features/study_runtime/study_conversation_runtime.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'conversation_runtime_test.dart' show TestCloud, TestTts;

class PcmRecorder extends AudioRecorder {
  final frames = StreamController<Uint8List>.broadcast(sync: true);
  Completer<void>? opening;
  bool capturing = false, disposed = false;
  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    await opening?.future;
    capturing = true;
    return frames.stream;
  }

  @override
  Future<bool> isRecording() async => capturing;
  @override
  Future<String?> stop() async {
    capturing = false;
    await frames.close();
    return null;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class AsrAdapter implements HttpClientAdapter {
  final pending = <Completer<void>>[];
  final sizes = <int>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.uri.path, '/v1/speech_to_text');
    expect(
      Map.fromEntries((options.data as FormData).fields)['model'],
      'asr-1.0',
    );
    sizes.add((options.data as FormData).files.single.value.length);
    final gate = Completer<void>();
    pending.add(gate);
    await gate.future;
    return ResponseBody.fromString(
      jsonEncode({'text': 'please save this word'}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> drain() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Uint8List voice() {
  final bytes = Uint8List(3200);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < 1600; i++) {
    data.setInt16(i * 2, 3000, Endian.little);
  }
  return bytes;
}

void segment(PcmRecorder recorder) {
  recorder.frames.add(voice());
  for (var i = 0; i < 8; i++) {
    recorder.frames.add(Uint8List(3200));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.namson.ai_secretary/config'),
      (_) async => 'test-non-secret',
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.namson.ai_secretary/call'),
      (_) async => null,
    );
  });
  test(
    'cloud VAD keeps onset A through late transcript then next onset owns B',
    () async {
      final recordings = <PcmRecorder>[];
      final adapter = AsrAdapter();
      final asr = StudyCloudAsr(
        dio: Dio()..httpClientAdapter = adapter,
        recorderFactory: () {
          final r = PcmRecorder();
          recordings.add(r);
          return r;
        },
      );
      var focus = 'A';
      final cloud = TestCloud();
      final saved = <String?>[];
      final runtime = StudyConversationRuntime(
        asr: asr,
        cloud: cloud,
        tts: TestTts(),
        captureContext: () => StudyInputContext(focusId: focus),
        onTool: (_, _, captured) async {
          saved.add(captured.focusId);
          return {'status': 'committed'};
        },
      );
      await runtime.startCall();
      recordings.last.frames.add(voice());
      focus = 'B';
      for (var i = 0; i < 8; i++) {
        recordings.last.frames.add(Uint8List(3200));
      }
      await drain();
      expect(adapter.pending.length, 1);
      expect(adapter.sizes.single, greaterThan(44));
      adapter.pending[0].complete();
      await drain();
      expect(saved, ['A']);
      segment(recordings.last);
      await drain();
      adapter.pending[1].complete();
      await drain();
      expect(saved, ['A', 'B']);
      await runtime.close();
      runtime.dispose();
    },
  );
  for (final action in ['mute', 'hangup']) {
    test(
      '$action cancels pending cloud ASR without any late tool submission',
      () async {
        final adapter = AsrAdapter();
        late PcmRecorder recorder;
        var calls = 0;
        final asr = StudyCloudAsr(
          dio: Dio()..httpClientAdapter = adapter,
          recorderFactory: () => recorder = PcmRecorder(),
        );
        final runtime = StudyConversationRuntime(
          asr: asr,
          cloud: TestCloud(),
          tts: TestTts(),
          onTool: (_, _, _) async {
            calls++;
            return {'status': 'committed'};
          },
        );
        await runtime.startCall();
        segment(recorder);
        await drain();
        if (action == 'mute') {
          await runtime.setMuted(true);
        } else {
          await runtime.endCall();
        }
        adapter.pending.single.complete();
        await drain();
        expect(calls, 0);
        expect(recorder.capturing, false);
        await runtime.close();
        runtime.dispose();
      },
    );
  }
  test(
    'cancel during native microphone start waits and releases late recording',
    () async {
      late PcmRecorder recorder;
      final gate = Completer<void>();
      final asr = StudyCloudAsr(
        recorderFactory: () => recorder = PcmRecorder()..opening = gate,
      );
      final starting = asr.start((_) {});
      await drain();
      final cancelling = asr.cancel();
      gate.complete();
      await starting;
      await cancelling;
      expect(recorder.capturing, false);
      expect(recorder.disposed, true);
    },
  );
}
