import 'package:ai_secretary/features/study_runtime/study_conversation_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'conversation_runtime_test.dart' show TestAsr, TestCloud, TestTts;

class FailedMic extends TestAsr {
  bool fail = false;
  @override
  Future<void> cancel() async {
    await super.cancel();
    if (fail) throw StateError('native microphone stop failure');
  }
}

class FailedAudio extends TestTts {
  bool fail = false;
  int attempts = 0;
  @override
  Future<void> stop() async {
    attempts++;
    if (fail) throw StateError('native playback stop failure');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in ['hangup', 'mute', 'cancelHold', 'close']) {
    test(
      '$action attempts every owner cleanup despite native stop errors',
      () async {
        final mic = FailedMic();
        final audio = FailedAudio();
        final cloud = TestCloud();
        var foregroundStops = 0;
        final runtime = StudyConversationRuntime(
          asr: mic,
          tts: audio,
          cloud: cloud,
          stopForeground: () async {
            foregroundStops++;
          },
        );
        if (action == 'cancelHold') {
          await runtime.startHold();
        } else {
          await runtime.startCall();
        }
        final previousMic = mic.stop.length, previousAudio = audio.attempts;
        mic.fail = true;
        audio.fail = true;
        switch (action) {
          case 'hangup':
            await runtime.endCall();
          case 'mute':
            await runtime.setMuted(true);
          case 'cancelHold':
            await runtime.cancelHold();
          case 'close':
            await runtime.close();
        }
        expect(mic.stop.length, greaterThan(previousMic));
        expect(audio.attempts, greaterThan(previousAudio));
        expect(runtime.error, contains('未完全成功'));
        if (action == 'hangup' || action == 'close') {
          expect(foregroundStops, 1);
        }
        await runtime.close();
        expect(foregroundStops, greaterThanOrEqualTo(1));
        expect(cloud.disposed, true);
        runtime.dispose();
      },
    );
  }
}
