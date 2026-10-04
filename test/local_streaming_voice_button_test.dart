import 'package:ai_secretary/features/chat/widgets/voice_button.dart';
import 'package:ai_secretary/providers/digital_human_provider.dart';
import 'package:ai_secretary/services/local_streaming_asr_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStreamingAsr extends LocalStreamingAsrService {
  PartialTranscript? partial;
  var cancelled = false;
  var finalText = '今天练背';

  @override
  Future<void> prepare() async {}

  @override
  Future<void> start(PartialTranscript onPartial) async {
    partial = onPartial;
  }

  @override
  Future<String> finish() async => finalText;

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  void dispose() {}
}

void main() {
  testWidgets('live partial is delivered before release and final once', (
    tester,
  ) async {
    final asr = _FakeStreamingAsr();
    final partials = <String>[];
    final finals = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localStreamingAsrProvider.overrideWithValue(asr)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: VoiceButton(onPartial: partials.add, onResult: finals.add),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(VoiceButton)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    asr.partial?.call('今天练');
    expect(partials, ['今天练']);
    expect(finals, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(finals, ['今天练背']);
  });

  testWidgets('slide-up cancel discards the recognized result', (tester) async {
    final asr = _FakeStreamingAsr();
    final finals = <String>[];
    var cancellations = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [localStreamingAsrProvider.overrideWithValue(asr)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: VoiceButton(
                onResult: finals.add,
                onCancel: () => cancellations++,
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(VoiceButton)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(asr.cancelled, isTrue);
    expect(cancellations, 1);
    expect(finals, isEmpty);
  });
}
