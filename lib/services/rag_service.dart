import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../core/database/database_helper.dart';
import '../core/utils/constants.dart';
import '../core/utils/logger.dart';
import '../models/memory_entry.dart';
import '../models/message.dart';
import '../models/rag_document.dart';
import 'embedding_service.dart';
import 'llm_service.dart';

class RagSearchResult {
  final RagDocument document;
  final double score;

  const RagSearchResult({required this.document, required this.score});
}

class RagAuditIssue {
  final String code;
  final String docKey;
  final String sourceType;
  final String? sourceId;
  final String message;
  final bool canRepair;

  const RagAuditIssue({
    required this.code,
    required this.docKey,
    required this.sourceType,
    this.sourceId,
    required this.message,
    required this.canRepair,
  });
}

class RagAuditReport {
  final int expectedDocuments;
  final int existingDocuments;
  final List<RagAuditIssue> issues;

  const RagAuditReport({
    required this.expectedDocuments,
    required this.existingDocuments,
    required this.issues,
  });

  bool get isHealthy => issues.isEmpty;

  Map<String, int> get issueCounts {
    final counts = <String, int>{};
    for (final issue in issues) {
      counts[issue.code] = (counts[issue.code] ?? 0) + 1;
    }
    return counts;
  }
}

class RagRepairReport {
  final RagAuditReport before;
  final RagAuditReport after;
  final int repairedIssues;
  final int failedIssues;

  const RagRepairReport({
    required this.before,
    required this.after,
    required this.repairedIssues,
    required this.failedIssues,
  });
}

abstract class RagVectorIndex {
  Future<List<RagSearchResult>> search({
    required List<double> queryEmbedding,
    int limit = 8,
    double minScore = 0.18,
  });
}

class SqliteRagVectorIndex implements RagVectorIndex {
  final DatabaseHelper _dbHelper;
  final int candidateLimit;

  SqliteRagVectorIndex(this._dbHelper, {this.candidateLimit = 500});

  @override
  Future<List<RagSearchResult>> search({
    required List<double> queryEmbedding,
    int limit = 8,
    double minScore = 0.18,
  }) async {
    if (candidateLimit <= 0 || limit <= 0) return const [];
    final documents = <RagDocument>[];
    final db = await _dbHelper.database;
    var offset = 0;
    // Invalid projections must not consume the candidate budget. Read bounded
    // pages until there are enough current candidates or the index is exhausted.
    while (documents.length < candidateLimit) {
      final page = await _dbHelper.getRagDocumentsWithEmbeddings(
        limit: candidateLimit,
        offset: offset,
      );
      if (page.isEmpty) break;
      final current = await RagService._currentDocuments(db, page);
      documents.addAll(current.take(candidateLimit - documents.length));
      offset += page.length;
      if (page.length < candidateLimit) break;
    }
    return RagService.rankDocuments(
      queryEmbedding: queryEmbedding,
      documents: documents,
      limit: limit,
      minScore: minScore,
    );
  }
}

class RagService {
  final DatabaseHelper _dbHelper;
  final EmbeddingProvider _embeddingService;
  final RagVectorIndex _vectorIndex;

  RagService({
    DatabaseHelper? dbHelper,
    EmbeddingProvider? embeddingService,
    RagVectorIndex? vectorIndex,
  }) : _dbHelper = dbHelper ?? DatabaseHelper.instance,
       _embeddingService = embeddingService ?? EmbeddingService(),
       _vectorIndex =
           vectorIndex ??
           SqliteRagVectorIndex(dbHelper ?? DatabaseHelper.instance);

  Future<void> indexMemory(MemoryEntry memory) async {
    await _upsertEmbeddedDocument(_memoryDocument(memory));
  }

  static RagDocument _memoryDocument(MemoryEntry memory) {
    final sourceId = memory.id?.toString() ?? memory.key;
    final content =
        '${memory.key}: ${memory.value}\n类别: ${memory.category}\n来源: ${memory.source}\n重要度: ${memory.importance}';
    return RagDocument(
      docKey: 'memory:$sourceId',
      sourceType: 'memory',
      sourceId: sourceId,
      title: '记忆：${memory.key}',
      content: content,
      metadataJson: jsonEncode({
        'category': memory.category,
        'importance': memory.importance,
        'confidence': memory.confidence,
        'source': memory.source,
      }),
    );
  }

  Future<int> deleteMemoryDocument(int memoryId) async {
    return _dbHelper.deleteRagDocument('memory:$memoryId');
  }

  Future<int> deleteUserProfileDocument() async {
    return _dbHelper.deleteRagDocument('user_profile:current');
  }

  Future<void> indexMessage(Message message) async {
    if (message.id == null || message.content.trim().isEmpty) return;
    await _upsertEmbeddedDocument(_messageDocument(message));
  }

  static RagDocument _messageDocument(Message message) {
    final roleLabel = message.isUser ? '用户消息' : 'AI回复';
    return RagDocument(
      docKey: 'message:${message.id}',
      sourceType: 'conversation_message',
      sourceId: message.id.toString(),
      title: '$roleLabel ${message.createdAt.toIso8601String()}',
      content: '${message.isUser ? "用户" : "助手"}：${message.content}',
      metadataJson: jsonEncode({
        'session_id': message.sessionId,
        'role': message.role,
        'created_at': message.createdAt.toIso8601String(),
      }),
    );
  }

  Future<void> indexUserProfile(Map<String, dynamic> profile) async {
    final document = _profileDocument(profile);
    if (document != null) await _upsertEmbeddedDocument(document);
  }

  static RagDocument? _profileDocument(Map<String, dynamic> profile) {
    if (profile.isEmpty) return null;
    final parts = <String>[];
    void add(String label, Object? value) {
      if (value != null && value.toString().trim().isNotEmpty) {
        parts.add('$label：$value');
      }
    }

    add('姓名', profile['name']);
    add('年龄', profile['age']);
    add('身高(cm)', profile['height']);
    add('体重(kg)', profile['weight']);
    add('健身水平', profile['fitnessLevel'] ?? profile['fitness_level']);
    add('目标', profile['goal']);
    add('健康限制', profile['conditions']);
    add('用户画像', profile['userPortrait']);
    add('补充信息', profile['customInfo']);

    if (parts.isEmpty) return null;
    return RagDocument(
      docKey: 'user_profile:current',
      sourceType: 'user_profile',
      sourceId: 'current',
      title: '用户档案',
      content: parts.join('\n'),
      metadataJson: jsonEncode(profile),
    );
  }

  Future<void> indexConversationSummary({
    required int id,
    String? docKey,
    String? sourceId,
    required String summary,
    String? topics,
    String? emotions,
  }) async {
    if (summary.trim().isEmpty) return;
    await _upsertEmbeddedDocument(
      _summaryDocument(
        docKey: docKey ?? 'conversation_summary:$id',
        sourceId: sourceId ?? id.toString(),
        summary: summary,
        topics: topics,
        emotions: emotions,
      ),
    );
  }

  static RagDocument _summaryDocument({
    required String docKey,
    required String sourceId,
    required String summary,
    String? topics,
    String? emotions,
  }) {
    return RagDocument(
      docKey: docKey,
      sourceType: 'conversation_summary',
      sourceId: sourceId,
      title: '对话摘要',
      content: [
        summary,
        if (topics != null && topics.trim().isNotEmpty) '主题：$topics',
        if (emotions != null && emotions.trim().isNotEmpty) '情绪：$emotions',
      ].join('\n'),
      metadataJson: jsonEncode({'topics': topics, 'emotions': emotions}),
    );
  }

  Future<void> indexWorkout(int workoutId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'training_workouts',
      where: 'id = ?',
      whereArgs: [workoutId],
      limit: 1,
    );
    if (rows.isEmpty) return;

    final setRows = await db.rawQuery(
      '''
      SELECT s.exercise_id, e.name as exercise_name, e.body_part, s.set_number,
             s.weight_kg, s.reps, s.duration_seconds, s.is_completed, s.note
      FROM training_sets s
      LEFT JOIN exercises e ON s.exercise_id = e.id
      WHERE s.workout_id = ?
      ORDER BY s.exercise_id ASC, s.set_number ASC
      ''',
      [workoutId],
    );
    await _upsertEmbeddedDocument(_workoutDocument(rows.first, setRows));
  }

  static RagDocument _workoutDocument(
    Map<String, Object?> workout,
    List<Map<String, Object?>> setRows,
  ) {
    final workoutId = workout['id'] as int;
    final title = workout['title']?.toString() ?? '训练记录';
    final volume = (workout['total_volume'] as num?)?.toDouble() ?? 0;
    final sets = workout['total_sets'] ?? 0;
    final duration = ((workout['duration'] as num?)?.toInt() ?? 0) ~/ 60;
    final note = workout['note']?.toString();
    final details = setRows.map((row) {
      final name =
          row['exercise_name']?.toString() ?? '动作#${row['exercise_id']}';
      final bodyPart = row['body_part']?.toString();
      final setNumber = row['set_number'] ?? '';
      final weight = (row['weight_kg'] as num?)?.toDouble() ?? 0;
      final reps = row['reps'] ?? 0;
      final seconds = (row['duration_seconds'] as num?)?.toInt() ?? 0;
      final completed = row['is_completed'] == 1 ? '已完成' : '未完成';
      final setNote = row['note']?.toString();
      return [
        '$name${bodyPart == null || bodyPart.isEmpty ? "" : "($bodyPart)"} 第$setNumber组 ${_formatWeight(weight)}kg x $reps $completed',
        if (seconds > 0) '持续$seconds秒',
        if (setNote != null && setNote.trim().isNotEmpty) '备注：$setNote',
      ].join('，');
    }).toList();

    return RagDocument(
      docKey: 'workout:$workoutId',
      sourceType: 'workout',
      sourceId: workoutId.toString(),
      title: '训练：$title',
      content: [
        '训练标题：$title',
        '开始时间：${workout['start_time'] ?? workout['created_at'] ?? ''}',
        '总容量：${volume.toStringAsFixed(0)}kg',
        '总组数：$sets',
        '训练时长：$duration分钟',
        if (note != null && note.trim().isNotEmpty) '训练备注：$note',
        if (details.isNotEmpty) '动作明细：${details.join('；')}',
      ].join('\n'),
      metadataJson: jsonEncode({
        'workout_id': workoutId,
        'total_volume': volume,
        'total_sets': sets,
        'duration_minutes': duration,
      }),
    );
  }

  Future<void> indexRecentWorkouts({int limit = 20}) async {
    final workouts = await _dbHelper.getRecentWorkouts(limit);
    for (final workout in workouts) {
      final id = workout['id'] as int?;
      if (id != null) {
        await indexWorkout(id);
      }
    }
  }

  Future<RagAuditReport> auditIndex() async {
    final db = await _dbHelper.database;
    final docs = await db.query('rag_documents');
    final docsByKey = {
      for (final doc in docs) doc['doc_key']?.toString() ?? '': doc,
    }..remove('');
    final issues = <RagAuditIssue>[];
    final expectedKeys = <String>{};
    var expectedDocuments = 0;

    void expectDocument({
      required String docKey,
      required String sourceType,
      required String sourceId,
      required String message,
    }) {
      expectedDocuments++;
      expectedKeys.add(docKey);
      if (!docsByKey.containsKey(docKey)) {
        issues.add(
          RagAuditIssue(
            code: 'missing_document',
            docKey: docKey,
            sourceType: sourceType,
            sourceId: sourceId,
            message: message,
            canRepair: true,
          ),
        );
      }
    }

    for (final doc in docs) {
      final embeddingJson = doc['embedding_json'] as String?;
      if (decodeEmbedding(embeddingJson) == null) {
        issues.add(
          RagAuditIssue(
            code: 'invalid_embedding',
            docKey: doc['doc_key']?.toString() ?? '',
            sourceType: doc['source_type']?.toString() ?? '',
            sourceId: doc['source_id']?.toString(),
            message: 'RAG document has no valid embedding',
            canRepair: true,
          ),
        );
      }
    }

    final now = DateTime.now().toIso8601String();
    final activeMemories = await db.query(
      'memories',
      where: DatabaseHelper.activeMemoryWhere,
      whereArgs: ['', now],
    );
    final activeMemoryIds = activeMemories
        .map((row) => row['id'])
        .whereType<int>()
        .toSet();
    for (final memory in activeMemories) {
      final id = memory['id'] as int?;
      if (id == null) continue;
      expectDocument(
        docKey: 'memory:$id',
        sourceType: 'memory',
        sourceId: id.toString(),
        message: 'Active memory is not indexed in RAG',
      );
    }
    for (final doc in docs.where((row) => row['source_type'] == 'memory')) {
      final memoryId = int.tryParse(doc['source_id']?.toString() ?? '');
      if (memoryId == null || !activeMemoryIds.contains(memoryId)) {
        issues.add(
          RagAuditIssue(
            code: 'orphan_document',
            docKey: doc['doc_key']?.toString() ?? '',
            sourceType: 'memory',
            sourceId: doc['source_id']?.toString(),
            message: 'RAG memory document no longer has an active memory row',
            canRepair: true,
          ),
        );
      }
    }

    final profile = await _loadUserProfilePreference(db);
    final hasProfile = profile.isNotEmpty;
    if (hasProfile) {
      expectDocument(
        docKey: 'user_profile:current',
        sourceType: 'user_profile',
        sourceId: 'current',
        message: 'User profile is not indexed in RAG',
      );
    } else if (docsByKey.containsKey('user_profile:current')) {
      issues.add(
        const RagAuditIssue(
          code: 'orphan_document',
          docKey: 'user_profile:current',
          sourceType: 'user_profile',
          sourceId: 'current',
          message: 'RAG user profile document exists without profile data',
          canRepair: true,
        ),
      );
    }

    final messages = await db.query(
      'conversations',
      where: 'content IS NOT NULL AND TRIM(content) != ?',
      whereArgs: [''],
    );
    final messageIds = messages
        .map((row) => row['id'])
        .whereType<int>()
        .toSet();
    for (final message in messages) {
      final id = message['id'] as int?;
      if (id == null) continue;
      expectDocument(
        docKey: 'message:$id',
        sourceType: 'conversation_message',
        sourceId: id.toString(),
        message: 'Conversation message is not indexed in RAG',
      );
    }
    for (final doc in docs.where(
      (row) => row['source_type'] == 'conversation_message',
    )) {
      final messageId = int.tryParse(doc['source_id']?.toString() ?? '');
      if (messageId == null || !messageIds.contains(messageId)) {
        issues.add(
          RagAuditIssue(
            code: 'orphan_document',
            docKey: doc['doc_key']?.toString() ?? '',
            sourceType: 'conversation_message',
            sourceId: doc['source_id']?.toString(),
            message:
                'RAG conversation message document no longer has a source row',
            canRepair: true,
          ),
        );
      }
    }

    final summaries = await db.query(
      'conversation_summaries',
      where: 'summary_text IS NOT NULL AND TRIM(summary_text) != ?',
      whereArgs: [''],
    );
    final summaryKeys = <String>{};
    for (final summary in summaries) {
      final id = summary['id'] as int?;
      if (id == null) continue;
      final sessionId = summary['session_id']?.toString();
      final key = sessionId == null || sessionId.isEmpty
          ? 'conversation_summary:$id'
          : 'conversation_summary:$sessionId';
      summaryKeys.add(key);
      expectDocument(
        docKey: key,
        sourceType: 'conversation_summary',
        sourceId: sessionId == null || sessionId.isEmpty
            ? id.toString()
            : sessionId,
        message: 'Conversation summary is not indexed in RAG',
      );
    }
    for (final doc in docs.where(
      (row) => row['source_type'] == 'conversation_summary',
    )) {
      final docKey = doc['doc_key']?.toString() ?? '';
      if (!summaryKeys.contains(docKey)) {
        issues.add(
          RagAuditIssue(
            code: 'orphan_document',
            docKey: docKey,
            sourceType: 'conversation_summary',
            sourceId: doc['source_id']?.toString(),
            message:
                'RAG conversation summary document no longer has a source row',
            canRepair: true,
          ),
        );
      }
    }

    final workouts = await db.query(
      'training_workouts',
      where:
          '(end_time IS NOT NULL AND TRIM(end_time) != ?) OR duration IS NOT NULL',
      whereArgs: [''],
    );
    final workoutIds = workouts
        .map((row) => row['id'])
        .whereType<int>()
        .toSet();
    for (final workout in workouts) {
      final id = workout['id'] as int?;
      if (id == null) continue;
      expectDocument(
        docKey: 'workout:$id',
        sourceType: 'workout',
        sourceId: id.toString(),
        message: 'Completed workout is not indexed in RAG',
      );
    }
    for (final doc in docs.where((row) => row['source_type'] == 'workout')) {
      final workoutId = int.tryParse(doc['source_id']?.toString() ?? '');
      if (workoutId == null || !workoutIds.contains(workoutId)) {
        issues.add(
          RagAuditIssue(
            code: 'orphan_document',
            docKey: doc['doc_key']?.toString() ?? '',
            sourceType: 'workout',
            sourceId: doc['source_id']?.toString(),
            message: 'RAG workout document no longer has a completed workout',
            canRepair: true,
          ),
        );
      }
    }

    final expectedProjections = docs
        .where((row) => expectedKeys.contains(row['doc_key']))
        .map(RagDocument.fromMap)
        .toList();
    final currentProjections = (await _currentDocuments(
      db,
      expectedProjections,
    )).toSet();
    for (final document in expectedProjections) {
      if (!currentProjections.contains(document)) {
        issues.add(
          RagAuditIssue(
            code: 'stale_document',
            docKey: document.docKey,
            sourceType: document.sourceType,
            sourceId: document.sourceId,
            message: 'RAG projection no longer matches its current source',
            canRepair: true,
          ),
        );
      }
    }

    return RagAuditReport(
      expectedDocuments: expectedDocuments,
      existingDocuments: docs.length,
      issues: issues,
    );
  }

  Future<RagRepairReport> repairIndex() async {
    final before = await auditIndex();
    var repaired = 0;
    var failed = 0;

    for (final issue in before.issues.where((issue) => issue.canRepair)) {
      try {
        final repairedIssue = await _repairAuditIssue(issue);
        if (repairedIssue) {
          repaired++;
        } else {
          failed++;
        }
      } catch (e) {
        failed++;
        Logger.e('RagService', 'Repair failed for ${issue.docKey}: $e');
      }
    }

    final after = await auditIndex();
    return RagRepairReport(
      before: before,
      after: after,
      repairedIssues: repaired,
      failedIssues: failed,
    );
  }

  Future<List<RagSearchResult>> search(
    String query, {
    int limit = 8,
    double minScore = 0.18,
  }) async {
    final normalized = query.trim();
    if (normalized.isEmpty) return const [];

    try {
      final queryEmbedding = await _embeddingService.embed(normalized);
      if (queryEmbedding.isEmpty) return const [];

      final results = await _vectorIndex.search(
        queryEmbedding: queryEmbedding,
        limit: limit,
        minScore: minScore,
      );
      if (!results.any(
        (result) => _managedSourceTypes.contains(result.document.sourceType),
      )) {
        return results.take(limit).toList();
      }
      // Also validate externally supplied vector-index results and recheck
      // sources that may have changed while the index was searching.
      final db = await _dbHelper.database;
      final current = (await _currentDocuments(
        db,
        results.map((result) => result.document).toList(),
      )).toSet();
      return results
          .where((result) => current.contains(result.document))
          .take(limit)
          .toList();
    } catch (e) {
      Logger.e('RagService', 'Vector search failed: $e');
      return const [];
    }
  }

  Future<String> buildContext(String query, {int limit = 8}) async {
    final results = await search(query, limit: limit);
    if (results.isEmpty) return '';

    return formatContext(results);
  }

  static String formatContext(List<RagSearchResult> results) {
    if (results.isEmpty) return '';

    final buffer = StringBuffer('\n[向量RAG检索]\n');
    for (final result in results) {
      final content = LlmService.sanitizeAssistantContent(
        result.document.content,
      );
      buffer.writeln(
        '- (${result.score.toStringAsFixed(3)}) ${result.document.title}: $content',
      );
    }
    return buffer.toString().trimRight();
  }

  static List<RagSearchResult> rankDocuments({
    required List<double> queryEmbedding,
    required List<RagDocument> documents,
    int limit = 8,
    double minScore = 0.18,
  }) {
    if (queryEmbedding.isEmpty) return const [];

    final results = <RagSearchResult>[];
    for (final document in documents) {
      final vector = decodeEmbedding(document.embeddingJson);
      if (vector == null) continue;

      final score = cosineSimilarity(queryEmbedding, vector);
      if (score >= minScore) {
        results.add(RagSearchResult(document: document, score: score));
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(limit).toList();
  }

  static List<double>? decodeEmbedding(String? embeddingJson) {
    if (embeddingJson == null || embeddingJson.isEmpty) return null;

    try {
      final decoded = jsonDecode(embeddingJson);
      if (decoded is! List || decoded.isEmpty) return null;
      return decoded.map((v) => (v as num).toDouble()).toList();
    } catch (_) {
      return null;
    }
  }

  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0;
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  Future<void> _upsertEmbeddedDocument(RagDocument document) async {
    final trimmed = document.content.trim();
    if (trimmed.isEmpty) return;

    try {
      final db = await _dbHelper.database;
      final snapshot = document.copyWith(content: trimmed);
      if ((await _currentDocuments(db, [snapshot])).isEmpty) return;
      final embedding = await _embeddingService.embed(trimmed);
      if (embedding.isEmpty) return;
      // Never hold a DB transaction during a network request. Revalidate and
      // store atomically afterwards, so a late result cannot restore old data.
      await db.transaction((txn) async {
        if ((await _currentDocuments(txn, [snapshot])).isEmpty) return;
        await _dbHelper.upsertRagDocument(
          snapshot.copyWith(
            embeddingJson: jsonEncode(embedding),
            embeddingModel: AppConstants.embeddingModel,
          ),
          executor: txn,
        );
      });
    } catch (e) {
      Logger.e('RagService', 'Index document failed (${document.docKey}): $e');
    }
  }

  static const _managedSourceTypes = {
    'memory',
    'user_profile',
    'conversation_message',
    'conversation_summary',
    'workout',
  };

  static String _sourceReference(RagDocument document) {
    return document.sourceId ??
        document.docKey.substring(document.docKey.indexOf(':') + 1);
  }

  /// Build canonical projections in batches. This uses the same formatters as
  /// indexing and avoids one DB read per candidate. Unknown extension sources
  /// retain their existing behavior; this is not a namespace/permission filter.
  static Future<List<RagDocument>> _currentDocuments(
    DatabaseExecutor db,
    List<RagDocument> documents,
  ) async {
    final grouped = <String, List<RagDocument>>{};
    for (final document in documents) {
      grouped.putIfAbsent(document.sourceType, () => []).add(document);
    }
    final accepted = <RagDocument>{};
    for (final group in grouped.entries) {
      final type = group.key;
      final candidates = group.value;
      if (!_managedSourceTypes.contains(type)) {
        accepted.addAll(candidates);
        continue;
      }
      final references = candidates.map(_sourceReference).toSet();
      final ids = references.map(int.tryParse).whereType<int>().toSet();
      final sources = <String, RagDocument>{};
      switch (type) {
        case 'memory':
          final rows = await _rowsForValues(db, 'memories', 'id', ids);
          final now = DateTime.now();
          for (final row in rows) {
            final memory = MemoryEntry.fromMap(row);
            if (memory.isActiveAt(now)) {
              sources[memory.id.toString()] = _memoryDocument(memory);
            }
          }
        case 'conversation_message':
          final rows = await _rowsForValues(db, 'conversations', 'id', ids);
          for (final row in rows) {
            final message = Message.fromMap(row);
            if (message.content.trim().isNotEmpty) {
              sources[message.id.toString()] = _messageDocument(message);
            }
          }
        case 'user_profile':
          final profile = await _loadUserProfilePreference(db);
          final projection = _profileDocument(profile);
          if (projection != null) sources['current'] = projection;
        case 'conversation_summary':
          final bySession = await _rowsForValues(
            db,
            'conversation_summaries',
            'session_id',
            references,
          );
          final byId = await _rowsForValues(
            db,
            'conversation_summaries',
            'id',
            ids,
          );
          final summaries = <String, Map<String, Object?>>{};
          for (final row in bySession) {
            summaries.putIfAbsent(row['session_id'].toString(), () => row);
          }
          for (final row in byId) {
            summaries.putIfAbsent(row['id'].toString(), () => row);
          }
          for (final candidate in candidates) {
            final reference = _sourceReference(candidate);
            final row = summaries[reference];
            final text = row?['summary_text']?.toString();
            if (row != null && text != null && text.trim().isNotEmpty) {
              final projection = _summaryDocument(
                docKey: candidate.docKey,
                sourceId: reference,
                summary: text,
                topics: row['topics']?.toString(),
                emotions: row['emotion_tags']?.toString(),
              );
              if (_sameProjection(candidate, projection)) {
                accepted.add(candidate);
              }
            }
          }
          continue;
        case 'workout':
          final workouts = await _rowsForValues(
            db,
            'training_workouts',
            'id',
            ids,
          );
          final setsByWorkout = <int, List<Map<String, Object?>>>{};
          final workoutIds = workouts.map((row) => row['id'] as int).toList();
          for (var start = 0; start < workoutIds.length; start += 400) {
            final batch = workoutIds.skip(start).take(400).toList();
            final rows = await db.rawQuery('''
              SELECT s.workout_id, s.exercise_id, e.name AS exercise_name,
                     e.body_part, s.set_number, s.weight_kg, s.reps,
                     s.duration_seconds, s.is_completed, s.note
              FROM training_sets s
              LEFT JOIN exercises e ON s.exercise_id = e.id
              WHERE s.workout_id IN (${List.filled(batch.length, '?').join(',')})
              ORDER BY s.workout_id ASC, s.exercise_id ASC, s.set_number ASC
            ''', batch);
            for (final row in rows) {
              setsByWorkout
                  .putIfAbsent(row['workout_id'] as int, () => [])
                  .add(row);
            }
          }
          for (final workout in workouts) {
            final id = workout['id'] as int;
            sources[id.toString()] = _workoutDocument(
              workout,
              setsByWorkout[id] ?? [],
            );
          }
      }
      for (final candidate in candidates) {
        final projection = sources[_sourceReference(candidate)];
        if (projection != null && _sameProjection(candidate, projection)) {
          accepted.add(candidate);
        }
      }
    }
    return documents.where(accepted.contains).toList();
  }

  static Future<List<Map<String, Object?>>> _rowsForValues(
    DatabaseExecutor db,
    String table,
    String column,
    Iterable<Object> values,
  ) async {
    final unique = values.toSet().toList();
    final rows = <Map<String, Object?>>[];
    // Stay below the older Android SQLite bind-parameter limit.
    for (var start = 0; start < unique.length; start += 400) {
      final batch = unique.skip(start).take(400).toList();
      rows.addAll(
        await db.query(
          table,
          where: '$column IN (${List.filled(batch.length, '?').join(',')})',
          whereArgs: batch,
          orderBy: 'id ASC',
        ),
      );
    }
    return rows;
  }

  static bool _sameProjection(RagDocument indexed, RagDocument current) {
    if (indexed.docKey != current.docKey ||
        indexed.sourceType != current.sourceType ||
        _sourceReference(indexed) != _sourceReference(current) ||
        indexed.title != current.title ||
        indexed.content.trim() != current.content.trim()) {
      return false;
    }
    try {
      return _sameMetadata(
        indexed.metadataJson == null
            ? const {}
            : jsonDecode(indexed.metadataJson!),
        current.metadataJson == null
            ? const {}
            : jsonDecode(current.metadataJson!),
      );
    } catch (_) {
      return false;
    }
  }

  static bool _sameMetadata(Object? left, Object? right) {
    if (left is Map && right is Map) {
      final a = Map<Object?, Object?>.from(left)
        ..removeWhere((_, value) => value == null || value == '');
      final b = Map<Object?, Object?>.from(right)
        ..removeWhere((_, value) => value == null || value == '');
      return a.length == b.length &&
          a.keys.every(
            (key) => b.containsKey(key) && _sameMetadata(a[key], b[key]),
          );
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var i = 0; i < left.length; i++) {
        if (!_sameMetadata(left[i], right[i])) return false;
      }
      return true;
    }
    return left == right;
  }

  Future<bool> _hasCurrentIndexedDocument(String docKey) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'rag_documents',
      where: 'doc_key = ?',
      whereArgs: [docKey],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final document = RagDocument.fromMap(rows.single);
    final embedding = decodeEmbedding(document.embeddingJson);
    if (embedding == null || embedding.isEmpty) return false;
    return (await _currentDocuments(db, [document])).isNotEmpty;
  }

  Future<bool> _repairAuditIssue(RagAuditIssue issue) async {
    if (issue.code == 'orphan_document') {
      await _dbHelper.deleteRagDocument(issue.docKey);
      return true;
    }

    final db = await _dbHelper.database;
    switch (issue.sourceType) {
      case 'memory':
        final id = int.tryParse(issue.sourceId ?? '');
        if (id == null) return false;
        final rows = await db.query(
          'memories',
          where: 'id = ? AND ${DatabaseHelper.activeMemoryWhere}',
          whereArgs: [id, '', DateTime.now().toIso8601String()],
          limit: 1,
        );
        if (rows.isEmpty) {
          await _dbHelper.deleteRagDocument(issue.docKey);
          return true;
        }
        await indexMemory(MemoryEntry.fromMap(rows.first));
        return _hasCurrentIndexedDocument(issue.docKey);
      case 'user_profile':
        final profile = await _loadUserProfilePreference(db);
        if (profile.isEmpty) {
          await _dbHelper.deleteRagDocument(issue.docKey);
          return true;
        } else {
          await indexUserProfile(profile);
        }
        return _hasCurrentIndexedDocument(issue.docKey);
      case 'conversation_message':
        final id = int.tryParse(issue.sourceId ?? '');
        if (id == null) return false;
        final rows = await db.query(
          'conversations',
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (rows.isEmpty) {
          await _dbHelper.deleteRagDocument(issue.docKey);
          return true;
        } else {
          await indexMessage(Message.fromMap(rows.first));
        }
        return _hasCurrentIndexedDocument(issue.docKey);
      case 'conversation_summary':
        final rows = await _summaryRowsForIssue(db, issue);
        if (rows.isEmpty) {
          await _dbHelper.deleteRagDocument(issue.docKey);
          return true;
        }
        final row = rows.first;
        final id = row['id'] as int?;
        if (id == null) return false;
        await indexConversationSummary(
          id: id,
          docKey: issue.docKey,
          sourceId: issue.sourceId,
          summary: row['summary_text']?.toString() ?? '',
          topics: row['topics']?.toString(),
          emotions: row['emotion_tags']?.toString(),
        );
        return _hasCurrentIndexedDocument(issue.docKey);
      case 'workout':
        final id = int.tryParse(issue.sourceId ?? '');
        if (id == null) return false;
        final rows = await db.query(
          'training_workouts',
          where:
              'id = ? AND ((end_time IS NOT NULL AND TRIM(end_time) != ?) OR duration IS NOT NULL)',
          whereArgs: [id, ''],
          limit: 1,
        );
        if (rows.isEmpty) {
          await _dbHelper.deleteRagDocument(issue.docKey);
          return true;
        } else {
          await indexWorkout(id);
        }
        return _hasCurrentIndexedDocument(issue.docKey);
    }
    return false;
  }

  Future<List<Map<String, dynamic>>> _summaryRowsForIssue(
    Database db,
    RagAuditIssue issue,
  ) async {
    final sourceId = issue.sourceId;
    if (sourceId != null && sourceId.isNotEmpty) {
      final bySession = await db.query(
        'conversation_summaries',
        where: 'session_id = ?',
        whereArgs: [sourceId],
        limit: 1,
      );
      if (bySession.isNotEmpty) return bySession;

      final numericId = int.tryParse(sourceId);
      if (numericId != null) {
        return db.query(
          'conversation_summaries',
          where: 'id = ?',
          whereArgs: [numericId],
          limit: 1,
        );
      }
    }
    final keyId = int.tryParse(issue.docKey.split(':').last);
    if (keyId == null) return const [];
    return db.query(
      'conversation_summaries',
      where: 'id = ?',
      whereArgs: [keyId],
      limit: 1,
    );
  }

  static Future<Map<String, dynamic>> _loadUserProfilePreference(
    DatabaseExecutor db,
  ) async {
    final rows = await db.query(
      'user_preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['user_profile'],
      limit: 1,
    );
    if (rows.isEmpty) return <String, dynamic>{};
    final raw = rows.first['value'] as String?;
    if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return <String, dynamic>{};
      decoded.removeWhere((_, value) => value == null || value == '');
      return decoded;
    } catch (e) {
      Logger.e('RagService', 'Invalid user_profile preference json: $e');
      return <String, dynamic>{};
    }
  }

  static String _formatWeight(double value) {
    return value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 1);
  }
}
