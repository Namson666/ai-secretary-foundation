import 'dart:async';
import 'dart:convert';

import 'package:ai_secretary/core/database/database_helper.dart';
import 'package:ai_secretary/models/memory_entry.dart';
import 'package:ai_secretary/models/message.dart';
import 'package:ai_secretary/services/embedding_service.dart';
import 'package:ai_secretary/services/rag_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ControlledEmbeddings implements EmbeddingProvider {
  bool fail = false;
  List<double> result = [1.0, 0.0];
  Completer<void>? started;
  Completer<void>? release;

  @override
  Future<List<double>> embed(String text) async {
    if (fail) throw StateError('embedding unavailable');
    final gate = release;
    if (gate != null) {
      release = null;
      started!.complete();
      await gate.future;
    }
    return result;
  }
}

void main() {
  late Database db;
  late DatabaseHelper helper;
  late _ControlledEmbeddings embeddings;
  late RagService service;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    helper = DatabaseHelper.instance;
    db = await helper.database;
  });

  setUp(() async {
    for (final table in [
      'memory_links',
      'training_sets',
      'training_workouts',
      'exercises',
      'memories',
      'rag_documents',
      'user_preferences',
      'user_profile',
      'conversations',
      'conversation_summaries',
    ]) {
      await db.delete(table);
    }
    embeddings = _ControlledEmbeddings();
    service = RagService(embeddingService: embeddings);
  });

  Future<MemoryEntry> saveMemory(String key, String value) async {
    final entry = MemoryEntry(key: key, value: value, source: 'manual');
    final id = await helper.insertMemory(entry);
    return entry.copyWith(id: id);
  }

  test('search excludes a memory that expired after indexing', () async {
    final memory = await saveMemory('plan', '明天学习');
    await service.indexMemory(memory);
    await db.update(
      'memories',
      {
        'expires_at': DateTime.now()
            .subtract(const Duration(seconds: 1))
            .toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [memory.id],
    );

    expect(await service.search('学习'), isEmpty);
  });

  test('search excludes a memory deleted without an index cleanup', () async {
    final memory = await saveMemory('plan', '明天学习');
    await service.indexMemory(memory);
    await helper.deleteMemory(memory.id!);

    expect(await service.search('学习'), isEmpty);
  });

  test('failed reindexing cannot expose the old canonical value', () async {
    final memory = await saveMemory('plan', '早上学习');
    await service.indexMemory(memory);
    final updated = memory.copyWith(value: '晚上学习');
    await helper.updateMemory(updated);
    embeddings.fail = true;
    await service.indexMemory(updated);
    embeddings.fail = false;

    expect(await service.search('学习'), isEmpty);
    final audit = await service.auditIndex();
    expect(audit.isHealthy, isFalse);
  });

  test('late embedding completion cannot resurrect a deleted memory', () async {
    final memory = await saveMemory('plan', '明天学习');
    final released = Completer<void>();
    embeddings.started = Completer<void>();
    embeddings.release = released;
    final indexing = service.indexMemory(memory);
    await embeddings.started!.future;
    await helper.deleteMemory(memory.id!);
    released.complete();
    await indexing;

    expect(await db.query('rag_documents'), isEmpty);
    expect(await service.search('学习'), isEmpty);
  });

  test('late old embedding cannot replace a newer memory projection', () async {
    final memory = await saveMemory('plan', '早上学习');
    final released = Completer<void>();
    embeddings.started = Completer<void>();
    embeddings.release = released;
    final oldIndexing = service.indexMemory(memory);
    await embeddings.started!.future;
    final updated = memory.copyWith(value: '晚上学习');
    await helper.updateMemory(updated);
    await service.indexMemory(updated);
    released.complete();
    await oldIndexing;

    final results = await service.search('学习');
    expect(results, hasLength(1));
    expect(results.single.document.content, contains('晚上学习'));
    expect(results.single.document.content, isNot(contains('早上学习')));
  });

  test(
    'invalid high-score candidates do not consume the result limit',
    () async {
      final valid = await saveMemory('valid', '晚上学习');
      await service.indexMemory(valid);
      for (var i = 0; i < 9; i++) {
        final stale = await saveMemory('stale_$i', '旧计划');
        await service.indexMemory(stale);
        await helper.deleteMemory(stale.id!);
      }

      final limitedIndex = RagService(
        embeddingService: embeddings,
        vectorIndex: SqliteRagVectorIndex(helper, candidateLimit: 2),
      );
      final results = await limitedIndex.search('学习', limit: 1);

      expect(results, hasLength(1));
      expect(results.single.document.docKey, 'memory:${valid.id}');
    },
  );

  test('index repair counts an unavailable embedding as a failure', () async {
    await saveMemory('plan', '明天学习');
    embeddings.fail = true;

    final repair = await service.repairIndex();

    expect(repair.repairedIssues, 0);
    expect(repair.failedIssues, 1);
    expect(repair.after.isHealthy, isFalse);
  });

  test(
    'an empty embedding cannot make an unrepaired index look healthy',
    () async {
      await saveMemory('plan', '明天学习');
      embeddings.result = [];

      final repair = await service.repairIndex();

      expect(repair.repairedIssues, 0);
      expect(repair.failedIssues, 1);
      expect(repair.after.isHealthy, isFalse);
    },
  );

  test('deleted conversation messages do not return through RAG', () async {
    final message = Message(
      sessionId: 'old_session',
      role: 'user',
      content: '旧对话',
    );
    final id = await helper.insertMessage(message);
    await service.indexMessage(message.copyWith(id: id));
    await helper.deleteSession('old_session');

    expect(await service.search('旧对话'), isEmpty);
  });

  test('profile changes invalidate its previous vector projection', () async {
    await db.insert('user_preferences', {
      'key': 'user_profile',
      'value': jsonEncode({'height': 180.0}),
    });
    await service.indexUserProfile({'height': 180.0});
    await db.update('user_preferences', {
      'value': jsonEncode({'height': 181.0}),
    });

    expect(await service.search('身高'), isEmpty);
  });

  test(
    'changed session summaries invalidate their previous projections',
    () async {
      final id = await helper.upsertConversationSummaryForSession('daily', {
        'summary_text': '早上学习',
        'topics': '学习',
        'emotion_tags': 'neutral',
      });
      await service.indexConversationSummary(
        id: id,
        docKey: 'conversation_summary:daily',
        sourceId: 'daily',
        summary: '早上学习',
        topics: '学习',
        emotions: 'neutral',
      );
      await helper.upsertConversationSummaryForSession('daily', {
        'summary_text': '晚上学习',
      });

      expect(await service.search('学习'), isEmpty);
    },
  );

  test('changed workout sets invalidate their previous projections', () async {
    final workoutId = await db.insert('training_workouts', {
      'title': '力量训练',
      'duration': 1200,
      'total_sets': 1,
    });
    final setId = await db.insert('training_sets', {
      'workout_id': workoutId,
      'set_number': 1,
      'weight_kg': 50.0,
      'reps': 10,
      'is_completed': 1,
    });
    await service.indexWorkout(workoutId);
    await db.update(
      'training_sets',
      {'reps': 5},
      where: 'id = ?',
      whereArgs: [setId],
    );

    expect(await service.search('训练'), isEmpty);
  });
}
