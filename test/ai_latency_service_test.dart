import 'package:ai_secretary/services/ai_latency_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('recordEvent persists AI latency diagnostics', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('''
      CREATE TABLE ai_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT, prompt_tokens INTEGER, completion_tokens INTEGER,
        latency_ms INTEGER, provider TEXT, success INTEGER, error_msg TEXT, created_at TEXT
      )
    ''');
    final service = AiLatencyService(openDatabase: () async => db);
    final trace = service.startTrace(sessionId: 'day_20260630');

    await Future<void>.delayed(const Duration(milliseconds: 1));
    await service.recordEvent(
      sessionId: trace.sessionId,
      provider: 'chat.llm_first_token',
      latency: trace.elapsed,
      promptTokens: 12,
      completionTokens: 3,
    );
    await service.recordEvent(
      sessionId: trace.sessionId,
      provider: 'chat.total',
      latency: const Duration(milliseconds: 2500),
      success: false,
      errorMessage: 'timeout',
    );
    await service.recordEvent(
      sessionId: trace.sessionId,
      provider: 'digital_voice.llm.MiniMax-M3.1-Flash-Preview',
      latency: const Duration(milliseconds: 860),
    );

    final rows = await db.query('ai_events', orderBy: 'id ASC');
    expect(rows, hasLength(3));
    expect(rows.first['session_id'], 'day_20260630');
    expect(rows.first['provider'], 'chat.llm_first_token');
    expect(rows.first['success'], 1);
    expect(rows.first['prompt_tokens'], 12);
    expect(rows.first['completion_tokens'], 3);
    expect(rows.first['latency_ms'], greaterThanOrEqualTo(0));
    expect(rows[1]['provider'], 'chat.total');
    expect(rows[1]['success'], 0);
    expect(rows[1]['error_msg'], 'timeout');
    expect(rows[1]['latency_ms'], 2500);

    final voiceRows = await service.getVoiceTestEvents();
    expect(voiceRows, hasLength(1));
    expect(
      voiceRows.single['provider'],
      'digital_voice.llm.MiniMax-M3.1-Flash-Preview',
    );
    expect(voiceRows.single['latency_ms'], 860);
  });
}
