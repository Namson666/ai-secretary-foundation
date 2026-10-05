import 'package:ai_secretary/features/study/application/study_runtime_provider.dart';
import 'package:ai_secretary/features/study/presentation/coach_page.dart';
import 'package:ai_secretary/features/study_runtime/study_avatar.dart';
import 'package:ai_secretary/features/study_runtime/study_conversation_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'conversation_runtime_test.dart' show TestAsr, TestCloud, TestTts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'expand/shrink reparents exactly one avatar and preserves active call; page exit ends it',
    (tester) async {
      var creates = 0;
      var disposes = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          expect((call.arguments as Map)['hybrid'], true);
          creates++;
          return creates;
        }
        if (call.method == 'dispose') disposes++;
        if (call.method == 'resize') return {'width': 360.0, 'height': 250.0};
        return null;
      });
      messenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('com.namson.ai_secretary/call'),
        (_) async => null,
      );
      final runtime = StudyConversationRuntime(
        asr: TestAsr(),
        cloud: TestCloud(),
        tts: TestTts(),
      );
      Widget app(bool active) => ProviderScope(
        overrides: [studyRuntimeProvider.overrideWithValue(runtime)],
        child: MaterialApp(
          home: Scaffold(body: StudyCoachPage(active: active)),
        ),
      );
      await tester.pumpWidget(app(true));
      await tester.pump();
      await tester.tap(find.text('实时通话'));
      await tester.pump();
      await tester.tap(find.byTooltip('开始实时语音通话'));
      await tester.pump();
      expect(runtime.callActive, true);
      final state = tester.state(find.byType(StudyAvatar));
      final before = creates;
      expect(before, greaterThan(0));
      await tester.tap(find.byTooltip('数字人全屏'));
      await tester.pump();
      expect(find.byType(StudyAvatar), findsOneWidget);
      expect(tester.state(find.byType(StudyAvatar)), same(state));
      expect(creates, before);
      expect(runtime.callActive, true);
      await tester.tap(find.byTooltip('静音'));
      await tester.pump();
      expect(runtime.muted, true);
      await tester.tap(find.byTooltip('收起全屏'));
      await tester.pump();
      expect(tester.state(find.byType(StudyAvatar)), same(state));
      expect(creates, before);
      expect(runtime.callActive, true);
      expect(runtime.muted, true);
      await tester.pumpWidget(app(false));
      await tester.pump();
      expect(runtime.callActive, false);
      expect(find.byType(StudyAvatar), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await runtime.close();
      runtime.dispose();
      expect(disposes, creates);
    },
  );
}
