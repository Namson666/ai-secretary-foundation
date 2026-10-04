import 'dart:convert';

import 'package:ai_secretary/core/database/database_helper.dart';
import 'package:ai_secretary/models/memory_entry.dart';
import 'package:ai_secretary/providers/memory_provider.dart';
import 'package:ai_secretary/services/embedding_service.dart';
import 'package:ai_secretary/services/rag_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeEmbeddingProvider implements EmbeddingProvider {
  @override
  Future<List<double>> embed(String text) async {
    return text.contains('晚上') ? [0.0, 1.0, 0.0] : [1.0, 0.0, 0.0];
  }
}

void main() {
  late DatabaseHelper dbHelper;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dbHelper = DatabaseHelper.instance;
    await dbHelper.database;
  });

  setUp(() async {
    final db = await dbHelper.database;
    await _clearUserData(db);
  });

  test('deleteMemory removes the matching RAG memory document', () async {
    final ragService = RagService(embeddingService: _FakeEmbeddingProvider());
    final container = ProviderContainer(
      overrides: [ragServiceProvider.overrideWithValue(ragService)],
    );
    addTearDown(container.dispose);

    final id = await dbHelper.insertMemory(
      MemoryEntry(
        key: 'training_preference',
        value: '早上训练',
        category: 'fitness',
        importance: 4,
        source: 'manual',
      ),
    );
    await ragService.indexMemory(
      MemoryEntry(
        id: id,
        key: 'training_preference',
        value: '早上训练',
        category: 'fitness',
        importance: 4,
        source: 'manual',
      ),
    );

    await container.read(memoryProvider.notifier).loadMemories();
    await container.read(memoryProvider.notifier).deleteMemory(id);

    final db = await dbHelper.database;
    final memories = await db.query(
      'memories',
      where: 'id = ?',
      whereArgs: [id],
    );
    final ragDocs = await db.query(
      'rag_documents',
      where: 'doc_key = ?',
      whereArgs: ['memory:$id'],
    );

    expect(memories, isEmpty);
    expect(ragDocs, isEmpty);
    expect(container.read(memoryProvider).memories, isEmpty);
  });

  test('updateMemory reindexes the matching RAG memory document', () async {
    final ragService = RagService(embeddingService: _FakeEmbeddingProvider());
    final container = ProviderContainer(
      overrides: [ragServiceProvider.overrideWithValue(ragService)],
    );
    addTearDown(container.dispose);

    final id = await dbHelper.insertMemory(
      MemoryEntry(
        key: 'training_preference',
        value: '早上训练',
        category: 'fitness',
        importance: 4,
        source: 'manual',
      ),
    );
    final updated = MemoryEntry(
      id: id,
      key: 'training_preference',
      value: '晚上训练',
      category: 'fitness',
      importance: 5,
      confidence: 0.9,
      source: 'manual',
    );

    await container.read(memoryProvider.notifier).loadMemories();
    await container.read(memoryProvider.notifier).updateMemory(updated);

    final db = await dbHelper.database;
    final memories = await db.query(
      'memories',
      where: 'id = ?',
      whereArgs: [id],
    );
    final ragDocs = await db.query(
      'rag_documents',
      where: 'doc_key = ?',
      whereArgs: ['memory:$id'],
    );

    expect(memories.single['value'], '晚上训练');
    expect(ragDocs.single['content'], contains('training_preference: 晚上训练'));
    expect(ragDocs.single['content'], isNot(contains('早上训练')));
    expect(jsonDecode(ragDocs.single['embedding_json'] as String), [
      0.0,
      1.0,
      0.0,
    ]);
    expect(container.read(memoryProvider).memories.single.value, '晚上训练');
  });

  test(
    'updateMemory removes inactive memory from RAG and visible state',
    () async {
      final ragService = RagService(embeddingService: _FakeEmbeddingProvider());
      final container = ProviderContainer(
        overrides: [ragServiceProvider.overrideWithValue(ragService)],
      );
      addTearDown(container.dispose);

      final id = await dbHelper.insertMemory(
        MemoryEntry(
          key: 'training_preference',
          value: '早上训练',
          category: 'fitness',
          importance: 4,
          source: 'manual',
        ),
      );
      await ragService.indexMemory(
        MemoryEntry(
          id: id,
          key: 'training_preference',
          value: '早上训练',
          category: 'fitness',
          importance: 4,
          source: 'manual',
        ),
      );

      await container.read(memoryProvider.notifier).loadMemories();
      await container
          .read(memoryProvider.notifier)
          .updateMemory(
            MemoryEntry(
              id: id,
              key: 'training_preference',
              value: '早上训练',
              category: 'fitness',
              importance: 0,
              source: 'manual',
            ),
          );

      final db = await dbHelper.database;
      final memories = await db.query(
        'memories',
        where: 'id = ?',
        whereArgs: [id],
      );
      final ragDocs = await db.query(
        'rag_documents',
        where: 'doc_key = ?',
        whereArgs: ['memory:$id'],
      );

      expect(memories.single['importance'], 0);
      expect(ragDocs, isEmpty);
      expect(container.read(memoryProvider).memories, isEmpty);
    },
  );

  test('updateMemory syncs profile memory into user profile and RAG', () async {
    final ragService = RagService(embeddingService: _FakeEmbeddingProvider());
    final container = ProviderContainer(
      overrides: [ragServiceProvider.overrideWithValue(ragService)],
    );
    addTearDown(container.dispose);

    final id = await dbHelper.insertMemory(
      MemoryEntry(
        key: 'height',
        value: '180cm',
        category: 'health',
        importance: 4,
        source: 'manual',
      ),
    );
    final updated = MemoryEntry(
      id: id,
      key: 'height',
      value: '185cm',
      category: 'health',
      importance: 4,
      source: 'manual',
    );

    await container.read(memoryProvider.notifier).loadMemories();
    await container.read(memoryProvider.notifier).updateMemory(updated);

    final db = await dbHelper.database;
    final profileRows = await db.query(
      'user_preferences',
      where: 'key = ?',
      whereArgs: ['user_profile'],
    );
    final profile = jsonDecode(profileRows.single['value'] as String);
    final profileRag = await db.query(
      'rag_documents',
      where: 'doc_key = ?',
      whereArgs: ['user_profile:current'],
    );

    expect(profile['height'], 185.0);
    expect(profileRag.single['content'], contains('身高(cm)：185.0'));
  });

  test(
    'updateMemory removes inactive profile memory from profile and RAG',
    () async {
      final ragService = RagService(embeddingService: _FakeEmbeddingProvider());
      final container = ProviderContainer(
        overrides: [ragServiceProvider.overrideWithValue(ragService)],
      );
      addTearDown(container.dispose);

      final id = await dbHelper.insertMemory(
        MemoryEntry(
          key: 'height',
          value: '180cm',
          category: 'health',
          importance: 4,
          source: 'manual',
        ),
      );
      await container.read(memoryProvider.notifier).loadMemories();
      await container
          .read(memoryProvider.notifier)
          .updateMemory(
            MemoryEntry(
              id: id,
              key: 'height',
              value: '180cm',
              category: 'health',
              importance: 4,
              source: 'manual',
            ),
          );

      await container
          .read(memoryProvider.notifier)
          .updateMemory(
            MemoryEntry(
              id: id,
              key: 'height',
              value: '180cm',
              category: 'health',
              importance: 0,
              source: 'manual',
            ),
          );

      final db = await dbHelper.database;
      final profileRows = await db.query(
        'user_preferences',
        where: 'key = ?',
        whereArgs: ['user_profile'],
      );
      final profileRag = await db.query(
        'rag_documents',
        where: 'doc_key = ?',
        whereArgs: ['user_profile:current'],
      );
      final memoryRag = await db.query(
        'rag_documents',
        where: 'doc_key = ?',
        whereArgs: ['memory:$id'],
      );

      expect(profileRows, isEmpty);
      expect(profileRag, isEmpty);
      expect(memoryRag, isEmpty);
      expect(container.read(memoryProvider).memories, isEmpty);
    },
  );

  test(
    'deleteMemory removes profile memory from user profile and RAG',
    () async {
      final ragService = RagService(embeddingService: _FakeEmbeddingProvider());
      final container = ProviderContainer(
        overrides: [ragServiceProvider.overrideWithValue(ragService)],
      );
      addTearDown(container.dispose);

      final id = await dbHelper.insertMemory(
        MemoryEntry(
          key: 'height',
          value: '180cm',
          category: 'health',
          importance: 4,
          source: 'manual',
        ),
      );
      await container.read(memoryProvider.notifier).loadMemories();
      await container
          .read(memoryProvider.notifier)
          .updateMemory(
            MemoryEntry(
              id: id,
              key: 'height',
              value: '180cm',
              category: 'health',
              importance: 4,
              source: 'manual',
            ),
          );

      await container.read(memoryProvider.notifier).deleteMemory(id);

      final db = await dbHelper.database;
      final profileRows = await db.query(
        'user_preferences',
        where: 'key = ?',
        whereArgs: ['user_profile'],
      );
      final profileRag = await db.query(
        'rag_documents',
        where: 'doc_key = ?',
        whereArgs: ['user_profile:current'],
      );

      expect(profileRows, isEmpty);
      expect(profileRag, isEmpty);
    },
  );
}

Future<void> _clearUserData(DatabaseExecutor db) async {
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
