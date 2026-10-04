import 'dart:async';
import 'dart:io';

import 'package:ai_secretary/core/database/database_helper.dart';
import 'package:ai_secretary/models/message.dart';
import 'package:ai_secretary/providers/chat_provider.dart';
import 'package:ai_secretary/providers/settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/runtime_fakes.dart';

class _DeferredHistoryDatabase extends Fake implements DatabaseHelper {
  final loads = <String, Completer<List<Message>>>{};
  final historyList = Completer<List<Map<String, dynamic>>>();

  @override
  Future<List<Map<String, dynamic>>> getHistorySessions() => historyList.future;

  @override
  Future<List<Message>> getMessages(String sessionId) {
    return (loads[sessionId] ??= Completer<List<Message>>()).future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory databaseDirectory;
  late ControlledMemoryService memory;
  late ControlledLlmService llm;
  late ProviderContainer container;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    databaseDirectory = await Directory.systemTemp.createTemp(
      'chat_lifecycle_',
    );
    await databaseFactory.setDatabasesPath(databaseDirectory.path);
    await DatabaseHelper.instance.database;
  });

  tearDownAll(() async {
    await (await DatabaseHelper.instance.database).close();
    await databaseDirectory.delete(recursive: true);
  });

  setUp(() async {
    await (await DatabaseHelper.instance.database).delete('conversations');
    memory = ControlledMemoryService();
    llm = ControlledLlmService();
    container = ProviderContainer(
      overrides: [
        memoryServiceProvider.overrideWithValue(memory),
        llmServiceProvider.overrideWithValue(llm),
        aiLatencyServiceProvider.overrideWithValue(ControlledLatencyService()),
        settingsProvider.overrideWith(ControlledSettingsNotifier.new),
      ],
    );
  });

  tearDown(() => container.dispose());

  test('late user indexing cannot restore a cleared request', () async {
    memory.userIndexGate = Completer<void>();
    final notifier = container.read(chatProvider.notifier);
    final request = notifier.sendMessage('旧问题');
    await memory.userIndexEntered.future;

    notifier.clearMessages();
    memory.userIndexGate!.complete();
    await request;

    expect(container.read(chatProvider).messages, isEmpty);
    expect(container.read(chatProvider).isStreaming, isFalse);
    expect(llm.requests, isEmpty);
    // Cancellation does not roll back a user message already committed to SQLite.
    final saved = await DatabaseHelper.instance.getMessages(
      ChatNotifier.dailySessionId(),
    );
    expect(saved.map((message) => message.content), ['旧问题']);
  });

  test(
    'late context cannot start a model request in another session',
    () async {
      memory.contextGate = Completer<void>();
      final notifier = container.read(chatProvider.notifier);
      final request = notifier.sendMessage('旧问题');
      await memory.contextEntered.future;

      await notifier.switchToSession('selected-session');
      memory.contextGate!.complete();
      await request;
      await pumpEventQueue();

      expect(container.read(chatProvider).currentSessionId, 'selected-session');
      expect(container.read(chatProvider).messages, isEmpty);
      expect(container.read(chatProvider).isStreaming, isFalse);
      expect(llm.requests, isEmpty);
    },
  );

  test(
    'late assistant indexing cannot refill a cleared conversation',
    () async {
      memory.assistantIndexGate = Completer<void>();
      final notifier = container.read(chatProvider.notifier);
      await notifier.sendMessage('旧问题');
      await memory.assistantIndexEntered.future;

      notifier.clearMessages();
      memory.assistantIndexGate!.complete();
      await pumpEventQueue();

      expect(container.read(chatProvider).messages, isEmpty);
      expect(container.read(chatProvider).isStreaming, isFalse);
      final saved = await DatabaseHelper.instance.getMessages(
        ChatNotifier.dailySessionId(),
      );
      expect(saved.map((message) => message.content), ['旧问题', '测试回复']);
    },
  );

  test(
    'disposed provider ignores context completion without reading ref',
    () async {
      memory.contextGate = Completer<void>();
      final notifier = container.read(chatProvider.notifier);
      final request = notifier.sendMessage('旧问题');
      await memory.contextEntered.future;

      container.dispose();
      memory.contextGate!.complete();
      await expectLater(request, completes);
      expect(llm.requests, isEmpty);
    },
  );

  test(
    'history responses completing in reverse order keep the latest selection',
    () async {
      final db = _DeferredHistoryDatabase();
      container.dispose();
      container = ProviderContainer(
        overrides: [chatDatabaseProvider.overrideWithValue(db)],
      );
      final notifier = container.read(chatProvider.notifier);
      final first = notifier.switchToSession('session-a');
      final second = notifier.switchToSession('session-b');

      db.loads['session-b']!.complete([
        Message(sessionId: 'session-b', role: 'user', content: 'B 的消息'),
      ]);
      await second;
      db.loads['session-a']!.complete([
        Message(sessionId: 'session-a', role: 'user', content: 'A 的消息'),
      ]);
      await first;

      final state = container.read(chatProvider);
      expect(state.currentSessionId, 'session-b');
      expect(state.messages.map((message) => message.content), ['B 的消息']);
    },
  );

  test('clearing messages invalidates an outstanding history load', () async {
    final db = _DeferredHistoryDatabase();
    container.dispose();
    container = ProviderContainer(
      overrides: [chatDatabaseProvider.overrideWithValue(db)],
    );
    final notifier = container.read(chatProvider.notifier);
    final loading = notifier.loadHistory(sessionId: 'session-a');
    notifier.clearMessages();
    db.loads['session-a']!.complete([
      Message(sessionId: 'session-a', role: 'user', content: '不应重现'),
    ]);
    await loading;

    expect(container.read(chatProvider).messages, isEmpty);
  });

  test('disposed provider ignores a delayed history result', () async {
    final db = _DeferredHistoryDatabase();
    container.dispose();
    container = ProviderContainer(
      overrides: [chatDatabaseProvider.overrideWithValue(db)],
    );
    final loading = container
        .read(chatProvider.notifier)
        .loadHistory(sessionId: 'session-a');
    container.dispose();
    db.loads['session-a']!.complete([]);

    await expectLater(loading, completes);
  });

  test('provider rebuild suppresses an old history list completion', () async {
    final db = _DeferredHistoryDatabase();
    container.dispose();
    container = ProviderContainer(
      overrides: [chatDatabaseProvider.overrideWithValue(db)],
    );
    final loading = container.read(chatProvider.notifier).loadHistorySessions();
    container.invalidate(chatProvider);
    expect(container.read(chatProvider).historySessions, isEmpty);
    db.historyList.complete([
      {'session_id': 'stale-session'},
    ]);
    await loading;

    expect(container.read(chatProvider).historySessions, isEmpty);
  });
}
