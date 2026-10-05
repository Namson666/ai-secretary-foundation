import 'package:ai_secretary/features/study/presentation/study_receipt_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'only explicit undoable saved contributions offer undo; schedules never do',
    (tester) async {
      Future<void> show(Map<String, dynamic> receipt) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudyReceiptCard(
              receipt: receipt,
              undone: false,
              undoPending: false,
              enabled: true,
              onUndo: () {},
            ),
          ),
        ),
      );
      final common = {
        'status': 'committed',
        'operation_id': 'actual_receipt',
        'point_id': 'point',
      };
      await show({...common, 'schedule_status': 'planned', 'message': '已安排复习'});
      expect(find.text('撤销本次保存'), findsNothing);
      await show({
        ...common,
        'schedule_status': 'pending',
        'undoable': true,
        'message': '复习点已保存，时间尚未安排。',
      });
      expect(find.text('撤销本次保存'), findsOneWidget);
      expect(find.text('待安排 · 可在计划中确认时间'), findsOneWidget);
      await show({
        'status': 'rejected',
        'message': '当前指令已取消',
        'undoable': true,
      });
      expect(find.text('操作已保存'), findsNothing);
      expect(find.text('撤销本次保存'), findsNothing);
    },
  );
}
