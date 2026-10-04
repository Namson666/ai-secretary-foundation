import 'package:ai_secretary/providers/chat_provider.dart';
import 'package:ai_secretary/models/message.dart';
import 'package:ai_secretary/services/memory_policy.dart';
import 'package:ai_secretary/services/memory_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dailySessionId groups chat by local day', () {
    final id = ChatNotifier.dailySessionId(DateTime(2026, 6, 30, 23, 59));

    expect(id, 'day_20260630');
  });

  test('profile facts route to user profile and RAG', () {
    const policy = MemoryPolicy();

    final route = policy.route(
      key: 'height',
      value: '181cm',
      category: 'health',
      importance: 3,
    );

    expect(route.target, MemoryStorageTarget.userProfile);
    expect(route.profilePatch, {'height': 181.0});
    expect(route.loadEveryPrompt, isTrue);
    expect(route.indexInRag, isTrue);
  });

  test('high importance preferences load every prompt', () {
    const policy = MemoryPolicy();

    final route = policy.route(
      key: 'training_preference',
      value: '更喜欢上午训练',
      category: 'preference',
      importance: 3,
    );

    expect(route.target, MemoryStorageTarget.coreMemory);
    expect(route.normalizedImportance, 4);
    expect(route.loadEveryPrompt, isTrue);
  });

  test('ordinary long term facts stay searchable through RAG', () {
    const policy = MemoryPolicy();

    final route = policy.route(
      key: 'favorite_food',
      value: '三文鱼',
      category: 'life',
      importance: 2,
    );

    expect(route.target, MemoryStorageTarget.longTermMemory);
    expect(route.loadEveryPrompt, isFalse);
    expect(route.indexInRag, isTrue);
  });

  test('conversation digest keeps a compact daily memory summary', () {
    final digest = ConversationDigest.fromMessages([
      Message(
        sessionId: 'day_20260630',
        role: 'user',
        content: '我身高180，体重82kg，目标是减脂',
        createdAt: DateTime(2026, 6, 30, 9),
      ),
      Message(
        sessionId: 'day_20260630',
        role: 'assistant',
        content: '我会按减脂目标安排训练。',
        createdAt: DateTime(2026, 6, 30, 9, 1),
      ),
    ]);

    expect(digest, isNotNull);
    expect(digest!.summary, contains('最近对话摘要'));
    expect(digest.topics, contains('用户档案'));
    expect(digest.topics, contains('目标'));
    expect(digest.messageCount, 2);
  });
}
