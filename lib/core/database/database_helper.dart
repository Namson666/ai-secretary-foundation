import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../../models/memory_entry.dart';
import '../../models/message.dart';
import '../../models/rag_document.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';

class DatabaseHelper {
  static DatabaseHelper? _instance;
  static Database? _database;
  static const String activeMemoryWhere =
      '(importance IS NULL OR importance > 0) AND '
      '(expires_at IS NULL OR expires_at = ? OR expires_at > ?)';

  DatabaseHelper._internal();

  static DatabaseHelper get instance {
    _instance ??= DatabaseHelper._internal();
    return _instance!;
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, AppConstants.dbName);
    Logger.d('DatabaseHelper', 'Initializing database at: $path');
    return await openDatabase(
      path,
      version: AppConstants.dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    Logger.d('DatabaseHelper', 'Creating database tables (version $version)');

    await db.execute('''
      CREATE TABLE user_profile (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT, age INTEGER, height REAL, weight REAL,
        fitness_level TEXT, goal TEXT,
        created_at TEXT, updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT, role TEXT, content TEXT, emotion TEXT,
        token_count INTEGER, metadata_json TEXT, created_at TEXT
      )
    ''');

    await db.execute('''
	      CREATE TABLE conversation_summaries (
	        id INTEGER PRIMARY KEY AUTOINCREMENT,
	        session_id TEXT,
	        summary_text TEXT, topics TEXT, start_time TEXT, end_time TEXT,
	        message_count INTEGER, emotion_tags TEXT, created_at TEXT
	      )
    ''');

    await db.execute('''
      CREATE TABLE memories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT, value TEXT, category TEXT,
        importance INTEGER DEFAULT 3, confidence REAL DEFAULT 0.5,
        source TEXT, last_confirmed_at TEXT, expires_at TEXT, created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE memory_links (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        memory_id INTEGER, conversation_id INTEGER,
        source_type TEXT, created_at TEXT,
        FOREIGN KEY (memory_id) REFERENCES memories(id),
        FOREIGN KEY (conversation_id) REFERENCES conversations(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE health_metrics (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        metric_type TEXT, value REAL, unit TEXT, source TEXT, created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE ai_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT, prompt_tokens INTEGER, completion_tokens INTEGER,
        latency_ms INTEGER, provider TEXT, success INTEGER, error_msg TEXT, created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE training_workouts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT, start_time TEXT, end_time TEXT, duration INTEGER,
        total_volume REAL, total_sets INTEGER, note TEXT, rating INTEGER, created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE training_sets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        workout_id INTEGER, exercise_id INTEGER, set_number INTEGER,
        weight_kg REAL, reps INTEGER, is_completed INTEGER DEFAULT 0,
        is_left_right INTEGER DEFAULT 0, side TEXT DEFAULT 'none',
        rest_timer_seconds INTEGER, note TEXT, created_at TEXT,
        FOREIGN KEY (workout_id) REFERENCES training_workouts(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE exercises (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT, body_part TEXT, equipment TEXT, is_custom INTEGER DEFAULT 0,
        image_path TEXT, image_url TEXT, description TEXT, tips TEXT, created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE user_preferences (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT UNIQUE, value TEXT, updated_at TEXT
      )
    ''');

    await _createRagTables(db);
    await _createConversationSummaryIndexes(db);
    await createTrainingV6(db);

    Logger.d('DatabaseHelper', 'All tables created successfully');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    Logger.d(
      'DatabaseHelper',
      'Upgrading database from v$oldVersion to v$newVersion',
    );
    if (oldVersion < 2) {
      try {
        await db.execute('ALTER TABLE exercises ADD COLUMN image_url TEXT');
        Logger.d('DatabaseHelper', 'Added image_url column to exercises table');
      } catch (e) {
        Logger.d('DatabaseHelper', 'image_url column may already exist: $e');
      }
      // Catalog merge preserves IDs referenced by historical training sets.
    }
    if (oldVersion < 4) {
      await _createRagTables(db);
      Logger.d('DatabaseHelper', 'Created RAG tables for v4');
    }
    if (oldVersion < 5) {
      try {
        await db.execute(
          'ALTER TABLE conversation_summaries ADD COLUMN session_id TEXT',
        );
      } catch (e) {
        Logger.d(
          'DatabaseHelper',
          'conversation_summaries.session_id may already exist: $e',
        );
      }
      await _createConversationSummaryIndexes(db);
      Logger.d('DatabaseHelper', 'Updated conversation summaries for v5');
    }
    if (oldVersion < 6) await createTrainingV6(db);
  }

  static Future<void> createTrainingV6(DatabaseExecutor db) async {
    await db.execute(
      'ALTER TABLE exercises ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE training_sets ADD COLUMN duration_seconds INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute('''CREATE TABLE training_actions (
      id INTEGER PRIMARY KEY AUTOINCREMENT, request_key TEXT UNIQUE NOT NULL,
      session_id TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL,
      set_id INTEGER, created_at TEXT NOT NULL
    )''');
    await db.execute(
      'CREATE INDEX idx_training_actions_session ON training_actions(session_id, status)',
    );
  }

  Future<void> _createRagTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rag_documents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doc_key TEXT UNIQUE,
        source_type TEXT,
        source_id TEXT,
        title TEXT,
        content TEXT,
        metadata_json TEXT,
        embedding_json TEXT,
        embedding_model TEXT,
        created_at TEXT,
        updated_at TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_rag_documents_source
      ON rag_documents(source_type, source_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_rag_documents_updated
      ON rag_documents(updated_at)
    ''');
  }

  Future<void> _createConversationSummaryIndexes(Database db) async {
    await db.execute('''
	      CREATE INDEX IF NOT EXISTS idx_conversation_summaries_session
	      ON conversation_summaries(session_id)
	    ''');
  }

  // ---------------------------------------------------------------------------
  // Conversation / Message CRUD
  // ---------------------------------------------------------------------------

  /// Insert a message into the conversations table.
  Future<int> insertMessage(Message message) async {
    final db = await database;
    final id = await db.insert('conversations', message.toMap());
    Logger.d('DatabaseHelper', 'Inserted message id=$id role=${message.role}');
    return id;
  }

  /// Get all messages for a given session, ordered by creation time.
  Future<List<Message>> getMessages(String sessionId) async {
    final db = await database;
    final rows = await db.query(
      'conversations',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC',
    );
    return rows.map((r) => Message.fromMap(r)).toList();
  }

  /// Get distinct chat sessions with summary metadata.
  /// Returns list of maps with: session_id, last_time, last_content, message_count.
  Future<List<Map<String, dynamic>>> getHistorySessions() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT
        session_id,
        MAX(created_at) as last_time,
        (SELECT content FROM conversations c2
         WHERE c2.session_id = conversations.session_id
         ORDER BY created_at DESC LIMIT 1) as last_content,
        COUNT(*) as message_count
      FROM conversations
      GROUP BY session_id
      ORDER BY last_time DESC
    ''');
    return result;
  }

  /// Delete all messages for a given session.
  Future<int> deleteSession(String sessionId) async {
    final db = await database;
    return await db.delete(
      'conversations',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  // ---------------------------------------------------------------------------
  // Memory CRUD
  // ---------------------------------------------------------------------------

  /// Insert a memory entry.
  Future<int> insertMemory(MemoryEntry entry) async {
    final db = await database;
    // Keep lookup and merge in one transaction. The legacy schema has no
    // unique key constraint; separate queries allow concurrent inserts to race.
    return db.transaction((txn) async {
      final existing = await txn.query(
        'memories',
        where: 'key = ?',
        whereArgs: [entry.key],
        orderBy: 'id ASC',
        limit: 1,
      );

      if (existing.isNotEmpty) {
        final row = existing.first;
        final existingId = row['id'] as int;
        final existingSource = row['source']?.toString().trim().toLowerCase();
        final incomingSource = entry.source.trim().toLowerCase();
        // AI extraction is a suggestion, not a new explicit user confirmation.
        // A later manual/user_input correction can still replace this record.
        if ((existingSource == 'manual' || existingSource == 'user_input') &&
            incomingSource == 'ai_extract') {
          return existingId;
        }

        final existingImportance = row['importance'] as int? ?? 0;
        final existingConfidence = (row['confidence'] as num?)?.toDouble() ?? 0;
        final sameValue = row['value'] == entry.value;
        await txn.update(
          'memories',
          {
            'value': entry.value,
            'category': entry.category,
            'importance': entry.importance > existingImportance
                ? entry.importance
                : existingImportance,
            // Confidence belongs to a value. A changed value cannot inherit the
            // higher confidence of a contradictory, older fact.
            'confidence': sameValue && existingConfidence > entry.confidence
                ? existingConfidence
                : entry.confidence,
            'source': entry.source,
            'last_confirmed_at': DateTime.now().toIso8601String(),
            'expires_at': entry.expiresAt?.toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [existingId],
        );
        Logger.d(
          'DatabaseHelper',
          'Updated memory id=$existingId key=${entry.key}',
        );
        return existingId;
      }

      final id = await txn.insert('memories', entry.toMap());
      Logger.d('DatabaseHelper', 'Inserted memory id=$id key=${entry.key}');
      return id;
    });
  }

  /// Get all memories ordered by importance.
  Future<List<MemoryEntry>> getMemories({int limit = 50}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'memories',
      where: activeMemoryWhere,
      whereArgs: ['', now],
      orderBy: 'importance DESC, created_at DESC',
      limit: limit,
    );
    return rows.map((r) => MemoryEntry.fromMap(r)).toList();
  }

  /// Get memories with importance >= [minImportance].
  Future<List<MemoryEntry>> getImportantFacts(int minImportance) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'memories',
      where:
          'importance >= ? AND (expires_at IS NULL OR expires_at = ? OR expires_at > ?)',
      whereArgs: [minImportance, '', now],
      orderBy: 'importance DESC, created_at DESC',
    );
    return rows.map((r) => MemoryEntry.fromMap(r)).toList();
  }

  /// Get the most recent memories ordered by creation time descending.
  Future<List<MemoryEntry>> getRecentFacts(int limit) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'memories',
      where: activeMemoryWhere,
      whereArgs: ['', now],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map((r) => MemoryEntry.fromMap(r)).toList();
  }

  /// Get recent conversation summaries.
  Future<List<Map<String, dynamic>>> getRecentSummaries(int limit) async {
    final db = await database;
    final rows = await db.query(
      'conversation_summaries',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows;
  }

  /// Get recent workout records.
  Future<List<Map<String, dynamic>>> getRecentWorkouts(int limit) async {
    final db = await database;
    final rows = await db.query(
      'training_workouts',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows;
  }

  /// Get the first user profile row.
  Future<Map<String, dynamic>?> getUserProfile() async {
    final db = await database;
    final rows = await db.query('user_profile', limit: 1);
    return rows.isNotEmpty ? rows.first : null;
  }

  /// Delete a memory by id.
  Future<int> deleteMemory(int id) async {
    final db = await database;
    return await db.delete('memories', where: 'id = ?', whereArgs: [id]);
  }

  /// Update an existing memory entry.
  Future<void> updateMemory(MemoryEntry entry) async {
    final db = await database;
    await db.update(
      'memories',
      entry.toMap(),
      where: 'id = ?',
      whereArgs: [entry.id],
    );
  }

  /// Get memories filtered by category.
  Future<List<MemoryEntry>> getMemoriesByCategory(String category) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'memories',
      where: 'category = ? AND $activeMemoryWhere',
      whereArgs: [category, '', now],
      orderBy: 'importance DESC, created_at DESC',
    );
    return rows.map((r) => MemoryEntry.fromMap(r)).toList();
  }

  /// Insert a conversation summary.
  Future<int> insertConversationSummary(Map<String, dynamic> summary) async {
    final db = await database;
    final id = await db.insert('conversation_summaries', summary);
    Logger.d('DatabaseHelper', 'Inserted conversation summary id=$id');
    return id;
  }

  /// Upsert the latest digest for a session so daily conversations have one
  /// stable distilled summary instead of many duplicate summary rows.
  Future<int> upsertConversationSummaryForSession(
    String sessionId,
    Map<String, dynamic> summary,
  ) async {
    final db = await database;
    final existing = await db.query(
      'conversation_summaries',
      columns: ['id'],
      where: 'session_id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    final map = Map<String, dynamic>.from(summary)
      ..['session_id'] = sessionId
      ..['created_at'] = DateTime.now().toIso8601String();

    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      await db.update(
        'conversation_summaries',
        map,
        where: 'id = ?',
        whereArgs: [id],
      );
      Logger.d('DatabaseHelper', 'Updated conversation summary id=$id');
      return id;
    }

    final id = await db.insert('conversation_summaries', map);
    Logger.d('DatabaseHelper', 'Inserted conversation summary id=$id');
    return id;
  }

  /// Get total message count for a session.
  Future<int> getMessageCountForSession(String sessionId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM conversations WHERE session_id = ?',
      [sessionId],
    );
    return (result.first['count'] as int?) ?? 0;
  }

  /// Get the created_at of the first message in a session (session start time).
  Future<DateTime?> getSessionStartTime(String sessionId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT MIN(created_at) as start_time FROM conversations WHERE session_id = ?',
      [sessionId],
    );
    final startTime = result.first['start_time'] as String?;
    return startTime != null ? DateTime.parse(startTime) : null;
  }

  // ---------------------------------------------------------------------------
  // RAG document CRUD
  // ---------------------------------------------------------------------------

  Future<int> upsertRagDocument(
    RagDocument document, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await database;
    final existing = await db.query(
      'rag_documents',
      columns: ['id', 'created_at'],
      where: 'doc_key = ?',
      whereArgs: [document.docKey],
      limit: 1,
    );

    final now = DateTime.now().toIso8601String();
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      final map = document.toMap()
        ..remove('id')
        ..['created_at'] = existing.first['created_at']
        ..['updated_at'] = now;
      await db.update('rag_documents', map, where: 'id = ?', whereArgs: [id]);
      return id;
    }

    return await db.insert(
      'rag_documents',
      document.copyWith(updatedAt: DateTime.now()).toMap(),
    );
  }

  Future<List<RagDocument>> getRagDocumentsWithEmbeddings({
    int limit = 300,
    int offset = 0,
  }) async {
    final db = await database;
    final rows = await db.query(
      'rag_documents',
      where: 'embedding_json IS NOT NULL AND embedding_json != ?',
      whereArgs: [''],
      orderBy: 'updated_at DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map((r) => RagDocument.fromMap(r)).toList();
  }

  Future<List<RagDocument>> getRecentRagDocuments({int limit = 20}) async {
    final db = await database;
    final rows = await db.query(
      'rag_documents',
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map((r) => RagDocument.fromMap(r)).toList();
  }

  Future<int> deleteRagDocument(String docKey) async {
    final db = await database;
    return await db.delete(
      'rag_documents',
      where: 'doc_key = ?',
      whereArgs: [docKey],
    );
  }

  // ---------------------------------------------------------------------------
  // AI event / latency CRUD
  // ---------------------------------------------------------------------------

  Future<int> insertAiEvent(Map<String, dynamic> event) async {
    final db = await database;
    return db.insert('ai_events', {
      ...event,
      'created_at': event['created_at'] ?? DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getRecentAiEvents({int limit = 20}) async {
    final db = await database;
    return db.query('ai_events', orderBy: 'created_at DESC', limit: limit);
  }
}
