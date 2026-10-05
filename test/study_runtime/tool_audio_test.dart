import 'dart:async';
import 'package:ai_secretary/features/study_runtime/study_conversation_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'conversation_runtime_test.dart' show TestAsr, TestCloud, TestTts;

class ToolTts extends TestTts {
  final spoken = <String>[];
  Completer<void>? gate;
  final entered = Completer<void>();
  @override
  Future<void> speak(String text, {String? emotion}) async {
    spoken.add(text);
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
  }

  @override
  Future<void> stop() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual tool handler plays reference during thinking using the single TTS owner',
    () async {
      final tts = ToolTts();
      late StudyConversationRuntime runtime;
      bool? heard;
      runtime = StudyConversationRuntime(
        asr: TestAsr(),
        cloud: TestCloud(),
        tts: tts,
        onTool: (_, _, captured) async {
          expect(runtime.phase, StudyConversationPhase.thinking);
          heard = await runtime.playToolReference(
            'resilient',
            isCurrent: () => captured.isCurrent,
          );
          expect(runtime.phase, StudyConversationPhase.thinking);
          return {'status': 'ok', 'heard': heard};
        },
      );
      await runtime.sendText('play resilient');
      expect(heard, true);
      expect(tts.spoken.first, 'resilient');
      await runtime.close();
      runtime.dispose();
    },
  );
  test(
    'hangup interrupts a tool playback in call and no listening evidence is earned',
    () async {
      final tts = ToolTts();
      final asr = TestAsr();
      late StudyConversationRuntime runtime;
      bool? heard;
      runtime = StudyConversationRuntime(
        asr: asr,
        cloud: TestCloud(),
        tts: tts,
        onTool: (_, _, captured) async {
          expect(asr.stop.length, greaterThanOrEqualTo(2));
          heard = await runtime.playToolReference(
            'resilient',
            isCurrent: () => captured.isCurrent,
          );
          return {'status': 'ok', 'heard': heard};
        },
      );
      await runtime.startCall();
      tts.gate = Completer<void>();
      asr.onset();
      asr.utterance!('play resilient');
      await tts.entered.future;
      expect(runtime.phase, StudyConversationPhase.speaking);
      await runtime.endCall();
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(heard, false);
      expect(runtime.callActive, false);
      expect(runtime.messages.where((m) => !m.isUser), isEmpty);
      await runtime.close();
      runtime.dispose();
    },
  );
  test('tool playback respects disabled speaker and revoked lease', () async {
    final tts = ToolTts();
    final runtime = StudyConversationRuntime(
      asr: TestAsr(),
      cloud: TestCloud(),
      tts: tts,
    );
    runtime.phase = StudyConversationPhase.thinking;
    expect(
      await runtime.playToolReference('word', isCurrent: () => false),
      false,
    );
    await runtime.setSpeaker(false);
    expect(
      await runtime.playToolReference('word', isCurrent: () => true),
      false,
    );
    expect(tts.spoken, isEmpty);
    await runtime.close();
    runtime.dispose();
  });
}
