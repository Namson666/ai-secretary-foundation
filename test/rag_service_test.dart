import 'dart:convert';

import 'package:ai_secretary/models/rag_document.dart';
import 'package:ai_secretary/core/database/database_helper.dart';
import 'package:ai_secretary/services/embedding_service.dart';
import 'package:ai_secretary/services/rag_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeEmbeddingProvider implements EmbeddingProvider {
  @override
  Future<List<double>> embed(String text) async {
    return text.contains('卧推') ? [1.0, 0.0, 0.0] : [0.0, 1.0, 0.0];
  }
}

class _FakeVectorIndex implements RagVectorIndex {
  List<double>? capturedQueryEmbedding;
  int? capturedLimit;
  double? capturedMinScore;

  @override
  Future<List<RagSearchResult>> search({
    required List<double> queryEmbedding,
    int limit = 8,
    double minScore = 0.18,
  }) async {
    capturedQueryEmbedding = queryEmbedding;
    capturedLimit = limit;
    capturedMinScore = minScore;
    return [
      RagSearchResult(
        document: _doc(
          key: 'workout:42',
          sourceType: 'workout',
          title: '训练：胸部',
          content: '卧推 80kg x 5',
          embedding: [1.0, 0.0, 0.0],
        ),
        score: 0.92,
      ),
    ];
  }
}

RagDocument _doc({
  required String key,
  required String sourceType,
  required String title,
  required String content,
  List<double>? embedding,
  String? rawEmbeddingJson,
}) {
  return RagDocument(
    docKey: key,
    sourceType: sourceType,
    title: title,
    content: content,
    embeddingJson: rawEmbeddingJson ?? jsonEncode(embedding),
  );
}

void main() {
  late Database db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    await _clearUserData(db);
  });

  test('rankDocuments ranks the relevant workout document first', () {
    final docs = [
      _doc(
        key: 'user_profile:current',
        sourceType: 'user_profile',
        title: '用户档案',
        content: '身高 180cm 体重 82kg 目标 减脂',
        embedding: [0.0, 1.0, 0.0],
      ),
      _doc(
        key: 'workout:1',
        sourceType: 'workout',
        title: '训练：今日训练',
        content: '上斜哑铃卧推 50kg x 10 总容量 500kg',
        embedding: [1.0, 0.0, 0.0],
      ),
      _doc(
        key: 'memory:goal',
        sourceType: 'memory',
        title: '记忆：fitness_goal',
        content: '目标：减脂',
        embedding: [0.0, 0.8, 0.2],
      ),
    ];

    final results = RagService.rankDocuments(
      queryEmbedding: [0.98, 0.05, 0.0],
      documents: docs,
      minScore: 0.1,
    );

    expect(results, isNotEmpty);
    expect(results.first.document.docKey, 'workout:1');
    expect(results.first.score, greaterThan(0.99));
  });

  test(
    'rankDocuments skips malformed embeddings without dropping good docs',
    () {
      final docs = [
        _doc(
          key: 'bad:json',
          sourceType: 'memory',
          title: '坏向量',
          content: '不可解析',
          rawEmbeddingJson: '[not-json',
        ),
        _doc(
          key: 'bad:length',
          sourceType: 'memory',
          title: '维度不匹配',
          content: '长度不同',
          embedding: [1.0, 0.0],
        ),
        _doc(
          key: 'message:1',
          sourceType: 'conversation_message',
          title: '用户消息',
          content: '我想减脂',
          embedding: [0.0, 1.0, 0.0],
        ),
      ];

      final results = RagService.rankDocuments(
        queryEmbedding: [0.0, 1.0, 0.0],
        documents: docs,
        minScore: 0.1,
      );

      expect(results.map((r) => r.document.docKey), ['message:1']);
    },
  );

  test('formatContext emits vector RAG prompt block', () {
    final result = RagSearchResult(
      document: _doc(
        key: 'workout:1',
        sourceType: 'workout',
        title: '训练：今日训练',
        content: '上斜哑铃卧推 50kg x 10',
        embedding: [1.0],
      ),
      score: 0.875,
    );

    final context = RagService.formatContext([result]);

    expect(context, contains('[向量RAG检索]'));
    expect(context, contains('(0.875) 训练：今日训练'));
    expect(context, contains('上斜哑铃卧推 50kg x 10'));
  });

  test('formatContext hides MEMORY control tags from RAG prompt', () {
    final result = RagSearchResult(
      document: _doc(
        key: 'message:2',
        sourceType: 'conversation_message',
        title: 'AI回复',
        content:
            '已记录身高。\n[MEMORY: height=183cm, category=health, importance=high]\n之后会参考。',
        embedding: [1.0],
      ),
      score: 0.91,
    );

    final context = RagService.formatContext([result]);

    expect(context, contains('已记录身高'));
    expect(context, contains('之后会参考'));
    expect(context, isNot(contains('[MEMORY:')));
    expect(context, isNot(contains('height=183cm')));
  });

  test('RagService delegates retrieval to injectable vector index', () async {
    final vectorIndex = _FakeVectorIndex();
    final service = RagService(
      embeddingService: _FakeEmbeddingProvider(),
      vectorIndex: vectorIndex,
    );

    final results = await service.search('卧推训练', limit: 3, minScore: 0.4);

    expect(vectorIndex.capturedQueryEmbedding, [1.0, 0.0, 0.0]);
    expect(vectorIndex.capturedLimit, 3);
    expect(vectorIndex.capturedMinScore, 0.4);
    expect(results.single.document.docKey, 'workout:42');
  });

  test(
    'indexWorkout writes completed phone workout details into RAG',
    () async {
      final service = RagService(embeddingService: _FakeEmbeddingProvider());
      final now = DateTime(2026, 6, 30, 7, 30).toIso8601String();

      final exerciseId = await db.insert('exercises', {
        'name': '上斜哑铃卧推',
        'body_part': '胸',
        'equipment': '哑铃',
        'is_custom': 0,
        'created_at': now,
      });
      final workoutId = await db.insert('training_workouts', {
        'title': '胸部力量训练',
        'start_time': now,
        'end_time': now,
        'duration': 1800,
        'total_volume': 1200.0,
        'total_sets': 2,
        'note': '右肩轻微不适，控制离心',
        'rating': 4,
        'created_at': now,
      });
      await db.insert('training_sets', {
        'workout_id': workoutId,
        'exercise_id': exerciseId,
        'set_number': 1,
        'weight_kg': 50.0,
        'reps': 10,
        'is_completed': 1,
        'side': 'none',
        'created_at': now,
      });
      await db.insert('training_sets', {
        'workout_id': workoutId,
        'exercise_id': exerciseId,
        'set_number': 2,
        'weight_kg': 55.0,
        'reps': 8,
        'is_completed': 1,
        'note': '最后两次吃力',
        'side': 'none',
        'created_at': now,
      });

      await service.indexWorkout(workoutId);

      final rows = await db.query(
        'rag_documents',
        where: 'doc_key = ?',
        whereArgs: ['workout:$workoutId'],
      );
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row['source_type'], 'workout');
      expect(row['title'], '训练：胸部力量训练');
      expect(
        row['content'],
        allOf(
          contains('总容量：1200kg'),
          contains('总组数：2'),
          contains('训练时长：30分钟'),
          contains('上斜哑铃卧推(胸) 第1组 50kg x 10 已完成'),
          contains('上斜哑铃卧推(胸) 第2组 55kg x 8 已完成'),
          contains('备注：最后两次吃力'),
        ),
      );

      final context = await service.buildContext('卧推训练记录', limit: 3);
      expect(context, contains('[向量RAG检索]'));
      expect(context, contains('训练：胸部力量训练'));
      expect(context, contains('上斜哑铃卧推'));
    },
  );

  test('auditIndex and repairIndex reconcile RAG source coverage', () async {
    final service = RagService(embeddingService: _FakeEmbeddingProvider());
    final now = DateTime(2026, 6, 30, 8, 15).toIso8601String();

    final memoryId = await db.insert('memories', {
      'key': 'training_preference',
      'value': '早上训练',
      'category': 'preference',
      'importance': 4,
      'confidence': 0.9,
      'source': 'unit_test',
      'created_at': now,
    });
    final expiringMemoryId = await db.insert('memories', {
      'key': 'temporary_training_plan',
      'value': '明天练背',
      'category': 'fitness',
      'importance': 4,
      'confidence': 0.9,
      'source': 'unit_test',
      'expires_at': DateTime.now()
          .add(const Duration(days: 1))
          .toIso8601String(),
      'created_at': now,
    });
    final expiredMemoryId = await db.insert('memories', {
      'key': 'expired_training_plan',
      'value': '昨天练腿',
      'category': 'fitness',
      'importance': 5,
      'confidence': 0.9,
      'source': 'unit_test',
      'expires_at': DateTime.now()
          .subtract(const Duration(days: 1))
          .toIso8601String(),
      'created_at': now,
    });
    await db.insert('user_preferences', {
      'key': 'user_profile',
      'value': '{"height":182.0,"goal":"增肌"}',
      'updated_at': now,
    });
    final messageId = await db.insert('conversations', {
      'session_id': 'day_20260630',
      'role': 'user',
      'content': '我想安排卧推训练',
      'created_at': now,
    });
    await db.insert('conversation_summaries', {
      'session_id': 'day_20260630',
      'summary_text': '用户想安排卧推训练。',
      'topics': '训练,卧推',
      'start_time': now,
      'end_time': now,
      'message_count': 1,
      'emotion_tags': 'neutral',
      'created_at': now,
    });
    final exerciseId = await db.insert('exercises', {
      'name': '卧推',
      'body_part': '胸',
      'equipment': '杠铃',
      'is_custom': 0,
      'created_at': now,
    });
    final workoutId = await db.insert('training_workouts', {
      'title': '胸部训练',
      'start_time': now,
      'end_time': now,
      'duration': 1200,
      'total_volume': 800.0,
      'total_sets': 2,
      'created_at': now,
    });
    await db.insert('training_sets', {
      'workout_id': workoutId,
      'exercise_id': exerciseId,
      'set_number': 1,
      'weight_kg': 80.0,
      'reps': 5,
      'is_completed': 1,
      'side': 'none',
      'created_at': now,
    });

    await db.insert('rag_documents', {
      'doc_key': 'memory:$memoryId',
      'source_type': 'memory',
      'source_id': memoryId.toString(),
      'title': '损坏的记忆向量',
      'content': 'training_preference: 早上训练',
      'embedding_json': '[bad-json',
      'updated_at': now,
      'created_at': now,
    });
    await db.insert('rag_documents', {
      'doc_key': 'memory:99999',
      'source_type': 'memory',
      'source_id': '99999',
      'title': '孤儿记忆',
      'content': '已经不存在',
      'embedding_json': jsonEncode([0.0, 1.0, 0.0]),
      'updated_at': now,
      'created_at': now,
    });
    await db.insert('rag_documents', {
      'doc_key': 'memory:$expiredMemoryId',
      'source_type': 'memory',
      'source_id': expiredMemoryId.toString(),
      'title': '已过期记忆',
      'content': 'expired_training_plan: 昨天练腿',
      'embedding_json': jsonEncode([0.0, 1.0, 0.0]),
      'updated_at': now,
      'created_at': now,
    });

    final before = await service.auditIndex();
    expect(before.isHealthy, isFalse);
    expect(before.expectedDocuments, 6);
    expect(before.issueCounts['invalid_embedding'], 1);
    expect(before.issueCounts['missing_document'], 5);
    expect(before.issueCounts['orphan_document'], 2);

    final repair = await service.repairIndex();

    expect(repair.failedIssues, 0);
    expect(repair.repairedIssues, greaterThanOrEqualTo(6));
    expect(repair.after.isHealthy, isTrue);

    final keys = (await db.query(
      'rag_documents',
      orderBy: 'doc_key ASC',
    )).map((row) => row['doc_key']).toList();
    expect(
      keys,
      containsAll([
        'conversation_summary:day_20260630',
        'memory:$expiringMemoryId',
        'memory:$memoryId',
        'message:$messageId',
        'user_profile:current',
        'workout:$workoutId',
      ]),
    );
    expect(keys, isNot(contains('memory:99999')));
    expect(keys, isNot(contains('memory:$expiredMemoryId')));

    final repairedMemory = await db.query(
      'rag_documents',
      where: 'doc_key = ?',
      whereArgs: ['memory:$memoryId'],
    );
    expect(
      RagService.decodeEmbedding(
        repairedMemory.single['embedding_json'] as String?,
      ),
      isNotNull,
    );
  });
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
