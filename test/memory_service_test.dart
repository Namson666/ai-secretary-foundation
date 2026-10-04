import 'package:ai_secretary/core/database/database_helper.dart';
import 'package:ai_secretary/models/message.dart';
import 'package:ai_secretary/services/embedding_service.dart';
import 'package:ai_secretary/services/memory_service.dart';
import 'package:ai_secretary/services/rag_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeEmbeddingProvider implements EmbeddingProvider {
  @override
  Future<List<double>> embed(String text) async {
    final length = text.length.toDouble();
    final profileWeight = text.contains('身高') || text.contains('height')
        ? 1.0
        : 0.0;
    final preferenceWeight = text.contains('preference') || text.contains('训练')
        ? 1.0
        : 0.0;
    return [length, profileWeight, preferenceWeight];
  }
}

void main() {
  late Database db;
  late MemoryService service;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    db = await DatabaseHelper.instance.database;
    service = MemoryService(
      ragService: RagService(embeddingService: _FakeEmbeddingProvider()),
    );
  });

  setUp(() async {
    await _clearUserData(db);
  });

  test(
    'processAiResponse writes MEMORY tags to profile, memory, and RAG',
    () async {
      await service.processAiResponse(
        '已记录。[MEMORY: height=180cm, category=health, importance=high, confidence=0.9]\n'
        '[MEMORY: training_preference=早上训练, category=preference, importance=3]',
      );

      final heightMemory = await db.query(
        'memories',
        where: 'key = ?',
        whereArgs: ['height'],
      );
      expect(heightMemory.single['value'], '180cm');
      expect(heightMemory.single['category'], 'health');
      expect(heightMemory.single['importance'], 5);

      final preferenceMemory = await db.query(
        'memories',
        where: 'key = ?',
        whereArgs: ['training_preference'],
      );
      expect(preferenceMemory.single['value'], '早上训练');
      expect(preferenceMemory.single['category'], 'preference');
      expect(preferenceMemory.single['importance'], 4);

      final profileRows = await db.query(
        'user_preferences',
        where: 'key = ?',
        whereArgs: ['user_profile'],
      );
      expect(profileRows.single['value'], contains('"height":180.0'));

      final profileRag = await db.query(
        'rag_documents',
        where: 'doc_key = ?',
        whereArgs: ['user_profile:current'],
      );
      expect(profileRag.single['source_type'], 'user_profile');
      expect(profileRag.single['content'], contains('身高(cm)：180.0'));

      final memoryRag = await db.query(
        'rag_documents',
        where: 'source_type = ?',
        whereArgs: ['memory'],
        orderBy: 'doc_key ASC',
      );
      expect(memoryRag, hasLength(2));
      expect(
        memoryRag.map((row) => row['content'].toString()).join('\n'),
        allOf(contains('height: 180cm'), contains('training_preference: 早上训练')),
      );

      final context = await service.buildContext(query: '我身高多少，适合几点训练？');
      expect(context, contains('用户档案'));
      expect(context, contains('身高：180.0cm'));
      expect(context, contains('training_preference：早上训练'));
      expect(context, contains('[向量RAG检索]'));
    },
  );

  test(
    'buildApiMessagesForSession includes recent history and pending voice text',
    () async {
      final helper = DatabaseHelper.instance;
      await helper.insertMessage(
        Message(sessionId: 'day_20260630', role: 'user', content: '第一句'),
      );
      await helper.insertMessage(
        Message(sessionId: 'day_20260630', role: 'assistant', content: '第一答'),
      );
      await helper.insertMessage(
        Message(sessionId: 'day_20260630', role: 'user', content: '第二句'),
      );

      final messages = await service.buildApiMessagesForSession(
        sessionId: 'day_20260630',
        pendingUserText: '语音继续问',
        limit: 3,
      );

      expect(messages, [
        {'role': 'assistant', 'content': '第一答'},
        {'role': 'user', 'content': '第二句'},
        {'role': 'user', 'content': '语音继续问'},
      ]);
    },
  );

  test(
    'persistVoiceTurn writes voice conversation, memory tags, and RAG digest',
    () async {
      final savedMessages = await service.persistVoiceTurn(
        sessionId: 'day_20260630',
        userText: '我身高181，我要减脂',
        assistantRawContent:
            '好的，我会记住你的偏好。[MEMORY: training_preference=晚上训练, category=preference, importance=3]',
      );

      expect(savedMessages, hasLength(2));

      final rows = await db.query('conversations', orderBy: 'id ASC');
      expect(rows, hasLength(2));
      expect(rows.first['role'], 'user');
      expect(rows.first['content'], '我身高181，我要减脂');
      expect(rows.last['role'], 'assistant');
      expect(rows.last['content'], '好的，我会记住你的偏好。');
      expect(rows.last['content'], isNot(contains('[MEMORY:')));

      final profileRows = await db.query(
        'user_preferences',
        where: 'key = ?',
        whereArgs: ['user_profile'],
      );
      expect(profileRows.single['value'], contains('"height":181.0'));
      expect(profileRows.single['value'], contains('"goal":"减脂"'));

      final memories = await db.query('memories', orderBy: 'key ASC');
      expect(
        memories.map((row) => row['key']),
        containsAll(['fitness_goal', 'height', 'training_preference']),
      );

      final messageRag = await db.query(
        'rag_documents',
        where: 'source_type = ?',
        whereArgs: ['conversation_message'],
      );
      expect(messageRag, hasLength(2));
      expect(
        messageRag.map((row) => row['content'].toString()).join('\n'),
        allOf(contains('用户：我身高181'), contains('助手：好的，我会记住你的偏好。')),
      );

      final summaryRows = await db.query(
        'conversation_summaries',
        where: 'session_id = ?',
        whereArgs: ['day_20260630'],
      );
      expect(summaryRows, hasLength(1));

      final summaryRag = await db.query(
        'rag_documents',
        where: 'doc_key = ?',
        whereArgs: ['conversation_summary:day_20260630'],
      );
      expect(summaryRag, hasLength(1));
    },
  );

  test('buildContext ignores expired and inactive memories', () async {
    final now = DateTime.now();
    await db.insert('memories', {
      'key': 'temporary_plan',
      'value': '今晚练背',
      'category': 'fitness',
      'importance': 4,
      'confidence': 0.9,
      'source': 'unit_test',
      'expires_at': now.add(const Duration(days: 1)).toIso8601String(),
      'created_at': now.toIso8601String(),
    });
    await db.insert('memories', {
      'key': 'old_plan',
      'value': '昨天练腿',
      'category': 'fitness',
      'importance': 5,
      'confidence': 0.9,
      'source': 'unit_test',
      'expires_at': now.subtract(const Duration(days: 1)).toIso8601String(),
      'created_at': now.toIso8601String(),
    });
    await db.insert('memories', {
      'key': 'forgotten_plan',
      'value': '不要再提示',
      'category': 'fitness',
      'importance': 0,
      'confidence': 0.9,
      'source': 'unit_test',
      'created_at': now.toIso8601String(),
    });

    final context = await service.buildContext(query: '今晚训练安排');

    expect(context, contains('temporary_plan：今晚练背'));
    expect(context, isNot(contains('old_plan')));
    expect(context, isNot(contains('forgotten_plan')));
    expect(context, isNot(contains('昨天练腿')));
    expect(context, isNot(contains('不要再提示')));
  });

  test(
    'reconfirmed memory clears stale expiry and becomes active again',
    () async {
      final now = DateTime.now();
      await db.insert('memories', {
        'key': 'training_preference',
        'value': '晚上训练',
        'category': 'fitness',
        'importance': 4,
        'confidence': 0.8,
        'source': 'unit_test',
        'expires_at': now.subtract(const Duration(days: 1)).toIso8601String(),
        'created_at': now.subtract(const Duration(days: 10)).toIso8601String(),
      });

      await service.processAiResponse(
        '已更新。[MEMORY: training_preference=早上训练, category=preference, importance=3]',
      );

      final rows = await db.query(
        'memories',
        where: 'key = ?',
        whereArgs: ['training_preference'],
      );
      expect(rows, hasLength(1));
      expect(rows.single['value'], '早上训练');
      expect(rows.single['category'], 'preference');
      expect(rows.single['expires_at'], isNull);

      final context = await service.buildContext(query: '我喜欢什么时候训练？');
      expect(context, contains('training_preference：早上训练'));
      expect(context, isNot(contains('晚上训练')));

      final ragDocs = await db.query(
        'rag_documents',
        where: 'source_type = ?',
        whereArgs: ['memory'],
      );
      expect(ragDocs.single['content'], contains('training_preference: 早上训练'));
    },
  );

  test(
    'generic context excludes workout history while fitness context includes it',
    () async {
      final now = DateTime.now().toIso8601String();
      await db.insert('training_workouts', {
        'title': '周末胸部训练',
        'start_time': now,
        'created_at': now,
        'total_sets': 3,
        'total_volume': 800.0,
        'duration': 1200,
      });
      final generic = await service.buildContext(query: '这部电影的结局如何？');
      expect(generic, isNot(contains('周末胸部训练')));
      final fitness = await service.buildContext(
        query: '最近训练如何？',
        includeWorkoutHistory: true,
      );
      expect(fitness, contains('周末胸部训练'));
    },
  );
}

Future<void> _clearUserData(Database db) async {
  const tables = [
    'memory_links',
    'training_sets',
    'rag_documents',
    'conversation_summaries',
    'conversations',
    'memories',
    'health_metrics',
    'ai_events',
    'training_workouts',
    'exercises',
    'user_profile',
    'user_preferences',
  ];
  for (final table in tables) {
    await db.delete(table);
  }
}
