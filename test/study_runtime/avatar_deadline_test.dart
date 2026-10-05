import 'dart:async';
import 'package:ai_secretary/features/study_runtime/study_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'cold deadline begins at native creation; failed view retry ignores stale ready',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final createGate = Completer<void>();
      final ids = <int>[];
      var ready = 0;
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          ids.add((call.arguments as Map)['id'] as int);
          if (ids.length == 1) await createGate.future;
          return 1;
        }
        if (call.method == 'resize') return {'width': 360.0, 'height': 250.0};
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StudyAvatar(onReady: () => ready++)),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 80));
      expect(find.text('重试数字人'), findsNothing);
      createGate.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 179));
      expect(find.text('重试数字人'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('重试数字人'), findsOneWidget);
      expect(ready, 0);
      await tester.tap(find.text('重试数字人'));
      await tester.pump();
      await tester.pump();
      expect(ids.length, 2);
      Future<void> initialized(int id) async {
        // ignore: deprecated_member_use
        await messenger.handlePlatformMessage(
          'com.namson.ai_secretary/duix_view_$id',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('onDuixInitialized', true),
          ),
          (_) {},
        );
      }

      await initialized(ids.first);
      await tester.pump();
      expect(ready, 0);
      await initialized(ids.last);
      await tester.pump();
      expect(ready, 1);
      expect(find.text('正在载入数字人…'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 181));
      expect(tester.takeException(), isNull);
    },
  );
}
