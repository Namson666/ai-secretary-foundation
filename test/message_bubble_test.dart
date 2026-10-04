import 'package:ai_secretary/features/chat/widgets/message_bubble.dart';
import 'package:ai_secretary/models/message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('assistant bubble hides MEMORY control tags', (tester) async {
    final message = Message(
      sessionId: 'day_20260630',
      role: 'assistant',
      content:
          '已记录身高。\n[MEMORY: height=183cm, category=health, importance=high]\n之后会参考。',
      createdAt: DateTime(2026, 6, 30, 8, 20),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessageBubble(message: message)),
      ),
    );

    expect(find.textContaining('已记录身高'), findsOneWidget);
    expect(find.textContaining('之后会参考'), findsOneWidget);
    expect(find.textContaining('[MEMORY:'), findsNothing);
    expect(find.textContaining('height=183cm'), findsNothing);
  });
}
