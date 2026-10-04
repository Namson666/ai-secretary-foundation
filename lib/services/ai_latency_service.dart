import 'package:sqflite/sqflite.dart';

import '../core/database/database_helper.dart';
import '../core/utils/logger.dart';

class AiLatencyTrace {
  final String? sessionId;
  final Stopwatch _stopwatch;

  AiLatencyTrace._({required this.sessionId}) : _stopwatch = Stopwatch() {
    _stopwatch.start();
  }

  Duration get elapsed => _stopwatch.elapsed;
}

class AiLatencyService {
  final Future<Database> Function() _openDatabase;

  AiLatencyService({
    DatabaseHelper? dbHelper,
    Future<Database> Function()? openDatabase,
  }) : _openDatabase =
           openDatabase ??
           (() => (dbHelper ?? DatabaseHelper.instance).database);

  AiLatencyTrace startTrace({String? sessionId}) {
    return AiLatencyTrace._(sessionId: sessionId);
  }

  Future<void> recordEvent({
    String? sessionId,
    required String provider,
    required Duration latency,
    bool success = true,
    String? errorMessage,
    int? promptTokens,
    int? completionTokens,
  }) async {
    try {
      final db = await _openDatabase();
      final id = await db.insert('ai_events', {
        'session_id': sessionId,
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'latency_ms': latency.inMilliseconds,
        'provider': provider,
        'success': success ? 1 : 0,
        'error_msg': errorMessage,
        'created_at': DateTime.now().toIso8601String(),
      });
      Logger.d(
        'AiLatencyService',
        'Recorded $provider ${latency.inMilliseconds}ms success=$success id=$id',
      );
    } catch (e) {
      Logger.w('AiLatencyService', 'Failed to record latency event: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getRecentEvents({int limit = 20}) async {
    final db = await _openDatabase();
    return db.query('ai_events', orderBy: 'created_at DESC', limit: limit);
  }

  Future<List<Map<String, dynamic>>> getVoiceTestEvents({
    int limit = 100,
  }) async {
    final db = await _openDatabase();
    return db.query(
      'ai_events',
      where: 'provider LIKE ? OR provider LIKE ?',
      whereArgs: ['digital_voice.%', 'digital_text.%'],
      orderBy: 'id DESC',
      limit: limit,
    );
  }
}
