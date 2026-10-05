import 'dart:async';
import 'dart:typed_data';

import 'package:ai_secretary/features/study_runtime/study_cloud_client.dart';
import 'package:ai_secretary/features/study_runtime/study_conversation_runtime.dart';
import 'package:ai_secretary/services/local_streaming_asr_service.dart';
import 'package:ai_secretary/services/tts_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class TestAsr extends LocalStreamingAsrService {
  void Function(Uint8List)? pcm;
  PartialTranscript? utterance;
  final stop = <String>[];
  int listens = 0;
  Completer<void>? stopGate;
  @override
  Future<void> start(PartialTranscript onPartial) async {}
  @override
  Future<void> startConversation({
    required PartialTranscript onPartial,
    required PartialTranscript onUtterance,
    required void Function() onSpeechStart,
    void Function(Uint8List)? onPcm,
  }) async {
    listens++;
    pcm = onPcm;
    utterance = onUtterance;
  }

  @override
  Future<String> finish() async => 'please save this word';
  @override
  Future<void> cancel() async {
    stop.add('cancel');
    await stopGate?.future;
  }

  @override
  void dispose() {
    stop.add('dispose');
  }

  void onset() {
    final bytes = Uint8List(3200);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < 1600; i++) {
      data.setInt16(i * 2, 3000, Endian.little);
    }
    pcm?.call(bytes);
  }
}

class TestCloud extends StudyCloudClient {
  final captures = <StudyInputContext>[];
  Completer<void>? delay;
  bool disposed = false;
  @override
  Future<String> reply({
    required List<StudyChatMessage> messages,
    required StudyInputContext context,
    required List<Map<String, dynamic>> tools,
    required StudyToolHandler? onTool,
    required bool Function() isCurrent,
  }) async {
    captures.add(context);
    if (delay != null) await delay!.future;
    if (!isCurrent()) return '';
    await onTool?.call('save', {}, context.forToolCall('stable_call'));
    return 'Saved with a receipt.';
  }

  @override
  void cancel() {}
  @override
  void dispose() {
    disposed = true;
  }
}

class TestTts extends TtsService {
  @override
  Future<void> speak(String text, {String? emotion}) async {}
  @override
  Future<void> stop() async {}
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.namson.ai_secretary/call');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
  });

  test(
    'temporary inactive preserves the call; background releases it',
    () async {
      final asr = TestAsr();
      final runtime = StudyConversationRuntime(
        asr: asr,
        cloud: TestCloud(),
        tts: TestTts(),
      );
      await runtime.startCall();
      await runtime.setMuted(true);
      await runtime.setSpeaker(false);
      runtime.elapsed = const Duration(seconds: 17);
      final cancellations = asr.stop.length;

      runtime.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await Future<void>.delayed(Duration.zero);
      runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(runtime.callActive, true);
      expect(runtime.muted, true);
      expect(runtime.speakerEnabled, false);
      expect(runtime.elapsed, const Duration(seconds: 17));
      expect(asr.stop.length, cancellations);
      expect(asr.listens, 1);

      runtime.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(runtime.callActive, false);
      expect(asr.stop.length, greaterThan(cancellations));
      runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(runtime.callActive, false);
      await runtime.close();
      runtime.dispose();
    },
  );

  test('temporary inactive discards an unsent held recording', () async {
    final asr = TestAsr();
    final cloud = TestCloud();
    final runtime = StudyConversationRuntime(
      asr: asr,
      cloud: cloud,
      tts: TestTts(),
    );
    await runtime.startHold();
    runtime.didChangeAppLifecycleState(AppLifecycleState.inactive);
    await Future<void>.delayed(Duration.zero);
    runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await runtime.finishHold();
    expect(runtime.phase, StudyConversationPhase.idle);
    expect(asr.stop, contains('cancel'));
    expect(cloud.captures, isEmpty);
    expect(runtime.messages, isEmpty);
    await runtime.close();
    runtime.dispose();
  });

  test('hold input keeps word A through later screen switch to B', () async {
    var focus = 'A';
    final cloud = TestCloud();
    final committed = <String?>[];
    final runtime = StudyConversationRuntime(
      asr: TestAsr(),
      cloud: cloud,
      tts: TestTts(),
      captureContext: () => StudyInputContext(focusId: focus),
      onTool: (_, _, captured) async {
        committed.add(captured.focusId);
        return {'status': 'committed'};
      },
    );
    await runtime.startHold();
    focus = 'B';
    await runtime.finishHold();
    expect(cloud.captures.single.focusId, 'A');
    expect(committed, ['A']);
    await runtime.close();
    runtime.dispose();
  });

  test(
    'audio onset freezes A, later transcript stays A; next segment captures B',
    () async {
      var focus = 'A';
      final asr = TestAsr();
      final cloud = TestCloud();
      final runtime = StudyConversationRuntime(
        asr: asr,
        cloud: cloud,
        tts: TestTts(),
        captureContext: () => StudyInputContext(focusId: focus),
      );
      await runtime.startCall();
      asr.onset();
      focus = 'B';
      asr.utterance?.call('first');
      await Future<void>.delayed(Duration.zero);
      expect(cloud.captures.first.focusId, 'A');
      asr.onset();
      asr.utterance?.call('second');
      await Future<void>.delayed(Duration.zero);
      expect(cloud.captures.last.focusId, 'B');
      await runtime.endCall();
      expect(runtime.callActive, false);
      await runtime.close();
      runtime.dispose();
    },
  );

  for (final stop in ['mute', 'hangup', 'close']) {
    test('$stop rejects late cloud tool result', () async {
      final asr = TestAsr();
      final cloud = TestCloud()..delay = Completer<void>();
      var writes = 0;
      final runtime = StudyConversationRuntime(
        asr: asr,
        cloud: cloud,
        tts: TestTts(),
        onTool: (_, _, _) async {
          writes++;
          return {};
        },
      );
      await runtime.startCall();
      asr.onset();
      asr.utterance?.call('save');
      await Future<void>.delayed(Duration.zero);
      if (stop == 'mute') {
        await runtime.setMuted(true);
      }
      if (stop == 'hangup') {
        await runtime.endCall();
      }
      if (stop == 'close') {
        await runtime.close();
      }
      cloud.delay!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(writes, 0);
      expect(runtime.messages.where((m) => !m.isUser), isEmpty);
      await runtime.close();
      runtime.dispose();
    });
  }

  test('cancelled hold never requests cloud or commits receipt', () async {
    final cloud = TestCloud();
    final runtime = StudyConversationRuntime(
      asr: TestAsr(),
      cloud: cloud,
      tts: TestTts(),
    );
    await runtime.startHold();
    await runtime.cancelHold();
    await runtime.finishHold();
    expect(cloud.captures, isEmpty);
    expect(runtime.messages, isEmpty);
    await runtime.close();
    runtime.dispose();
  });
  test('rapid unmute waits asynchronous microphone teardown', () async {
    final asr = TestAsr();
    final runtime = StudyConversationRuntime(
      asr: asr,
      cloud: TestCloud(),
      tts: TestTts(),
    );
    await runtime.startCall();
    expect(asr.listens, 1);
    asr.stopGate = Completer<void>();
    final muting = runtime.setMuted(true);
    final unmuting = runtime.setMuted(false);
    await Future<void>.delayed(Duration.zero);
    expect(asr.listens, 1);
    asr.stopGate!.complete();
    await muting;
    await unmuting;
    expect(asr.listens, 2);
    asr.stopGate = null;
    await runtime.close();
    runtime.dispose();
  });
  test(
    'tool context carries stable command ID and actual text with revoked lease',
    () async {
      StudyInputContext? toolContext;
      final runtime = StudyConversationRuntime(
        asr: TestAsr(),
        cloud: TestCloud(),
        tts: TestTts(),
        onTool: (_, _, captured) async {
          toolContext = captured;
          return {'operation_id': 'fact'};
        },
      );
      await runtime.sendText('Please save this word');
      expect(toolContext!.finalText, 'Please save this word');
      expect(toolContext!.toolCallId, 'stable_call');
      expect(
        toolContext!.commandId,
        toolContext!.forToolCall('stable_call').commandId,
      );
      expect(toolContext!.isCurrent, true);
      await runtime.cancelHold();
      expect(toolContext!.isCurrent, false);
      await runtime.close();
      runtime.dispose();
    },
  );
}
