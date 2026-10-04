import 'dart:convert';

import 'package:ai_secretary/core/database/database_helper.dart';
import 'package:ai_secretary/models/memory_entry.dart';
import 'package:ai_secretary/services/embedding_service.dart';
import 'package:ai_secretary/services/memory_service.dart';
import 'package:ai_secretary/services/rag_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingEmbeddings implements EmbeddingProvider {
  final texts = <String>[];

  @override
  Future<List<double>> embed(String text) async {
    texts.add(text);
    return [1.0, 0.0];
  }
}

void main() {
  late Database db;
  late DatabaseHelper helper;
  late _RecordingEmbeddings embeddings;
  late MemoryService service;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    helper = DatabaseHelper.instance;
    db = await helper.database;
  });

  setUp(() async {
    for (final table in [
      'memory_links',
      'memories',
      'rag_documents',
      'user_preferences',
      'user_profile',
    ]) {
      await db.delete(table);
    }
    embeddings = _RecordingEmbeddings();
    service = MemoryService(
      ragService: RagService(embeddingService: embeddings),
    );
  });

  test(
    'AI guesses cannot replace an explicit fact or its projections',
    () async {
      await helper.insertMemory(
        MemoryEntry(
          key: 'height',
          value: '183cm',
          category: 'health',
          importance: 5,
          confidence: 0.95,
          source: 'manual',
        ),
      );

      await service.processAiResponse(
        '[MEMORY: height=170cm, category=health, confidence=0.7]',
      );

      final memory = (await db.query('memories')).single;
      expect(memory['value'], '183cm');
      expect(memory['source'], 'manual');
      expect(memory['confidence'], 0.95);
      final profile = (await db.query(
        'user_preferences',
        where: 'key = ?',
        whereArgs: ['user_profile'],
      )).single;
      expect(jsonDecode(profile['value'] as String)['height'], 183.0);
      final context = await service.buildContext(query: '身高');
      expect(context, contains('183'));
      expect(context, isNot(contains('170')));
      expect(
        (await db.query('rag_documents')).map((row) => row['content']).join(),
        isNot(contains('170')),
      );
    },
  );

  test('a later explicit correction replaces an older explicit fact', () async {
    await helper.insertMemory(
      MemoryEntry(
        key: 'height',
        value: '183cm',
        confidence: 0.95,
        source: 'manual',
      ),
    );

    await service.extractFromUserInput('身高改成181');

    final rows = await db.query(
      'memories',
      where: 'key = ?',
      whereArgs: ['height'],
    );
    expect(rows, hasLength(1));
    expect(rows.single['value'], '181 cm');
    expect(rows.single['source'], 'user_input');
    expect(rows.single['confidence'], 0.5);
    final context = await service.buildContext(query: '身高');
    expect(context, contains('181'));
    expect(context, isNot(contains('183')));
  });

  test('same-key concurrent writes produce a single canonical row', () async {
    final ids = await Future.wait([
      helper.insertMemory(
        MemoryEntry(
          key: 'preferred_language',
          value: 'English',
          source: 'user_input',
        ),
      ),
      helper.insertMemory(
        MemoryEntry(
          key: 'preferred_language',
          value: 'Chinese',
          source: 'user_input',
        ),
      ),
    ]);

    expect(ids.toSet(), hasLength(1));
    expect(await db.query('memories'), hasLength(1));
  });

  test('one extracted profile fact produces one profile embedding', () async {
    await service.extractFromUserInput('身高181');

    expect(
      embeddings.texts.where((text) => text.contains('身高(cm)：181.0')),
      hasLength(1),
    );
    expect(await db.query('memories'), hasLength(1));
    expect(await db.query('rag_documents'), hasLength(2));
  });
}
