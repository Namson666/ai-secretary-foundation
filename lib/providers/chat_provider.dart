import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/database_helper.dart';
import '../core/assistant/assistant_prompt.dart';
import '../core/utils/logger.dart';
import '../models/message.dart';
import '../services/ai_latency_service.dart';
import '../services/llm_service.dart';
import '../services/memory_service.dart';
import 'assistant_modules_provider.dart';
import 'settings_provider.dart';

// ---------------------------------------------------------------------------
// Service providers
// ---------------------------------------------------------------------------

final llmServiceProvider = Provider<LlmService>(
  (ref) => LlmService(model: () => ref.read(settingsProvider).llmModel),
);
final aiLatencyServiceProvider = Provider<AiLatencyService>(
  (ref) => AiLatencyService(),
);
final memoryServiceProvider = Provider<MemoryService>(
  (ref) => MemoryService(llmService: ref.read(llmServiceProvider)),
);
final chatDatabaseProvider = Provider<DatabaseHelper>(
  (ref) => DatabaseHelper.instance,
);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@immutable
class ChatState {
  final List<Message> messages;
  final String currentSessionId;
  final bool isStreaming;
  final String? error;
  final List<Map<String, dynamic>> historySessions;

  const ChatState({
    this.messages = const [],
    this.currentSessionId = '',
    this.isStreaming = false,
    this.error,
    this.historySessions = const [],
  });

  ChatState copyWith({
    List<Message>? messages,
    String? currentSessionId,
    bool? isStreaming,
    String? error,
    List<Map<String, dynamic>>? historySessions,
    bool clearError = false,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      currentSessionId: currentSessionId ?? this.currentSessionId,
      isStreaming: isStreaming ?? this.isStreaming,
      error: clearError ? null : (error ?? this.error),
      historySessions: historySessions ?? this.historySessions,
    );
  }

  List<Map<String, String>> get apiMessages {
    return messages
        .where((m) => m.content.trim().isNotEmpty)
        .toList()
        .takeLast(16)
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final chatProvider = NotifierProvider<ChatNotifier, ChatState>(
  ChatNotifier.new,
);

/// Provider for passing initial voice text from home screen to chat screen.
final initialVoiceTextProvider =
    NotifierProvider<InitialVoiceTextNotifier, String?>(
      InitialVoiceTextNotifier.new,
    );

class InitialVoiceTextNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setText(String? text) => state = text;
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class ChatNotifier extends Notifier<ChatState> {
  StreamSubscription<String>? _streamSubscription;
  int _requestGeneration = 0;
  int _historyListGeneration = 0;

  /// Track session start time for summary trigger logic.
  DateTime? _sessionStartTime;

  @override
  ChatState build() {
    ref.onDispose(() {
      _cancelRequest();
      // Riverpod can reuse this Notifier with a fresh Ref after invalidation.
      // A pending list query still belongs to the previous lifecycle.
      _historyListGeneration++;
    });
    return const ChatState();
  }

  bool _isCurrentRequest(int generation) =>
      ref.mounted && generation == _requestGeneration;

  void _cancelRequest() {
    _requestGeneration++;
    unawaited(_streamSubscription?.cancel());
    _streamSubscription = null;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Send a plain-text message.
  Future<void> sendMessage(String content) async {
    if (!ref.mounted) return;
    if (content.trim().isEmpty) return;
    if (state.isStreaming) return;
    final selection = AssistantInputSnapshot.capture(ref).select(content);
    final generation = ++_requestGeneration;
    final requestMessages = List<Message>.of(state.messages);
    state = state.copyWith(isStreaming: true, clearError: true);

    final llmService = ref.read(llmServiceProvider);
    final memoryService = ref.read(memoryServiceProvider);
    final latencyService = ref.read(aiLatencyServiceProvider);
    final dbHelper = ref.read(chatDatabaseProvider);

    final sessionId = state.currentSessionId.isEmpty
        ? dailySessionId()
        : state.currentSessionId;
    final trace = latencyService.startTrace(sessionId: sessionId);

    // Track session start time for summary trigger
    _sessionStartTime ??= DateTime.now();

    // 1. Add user message
    final userMessage = Message(
      sessionId: sessionId,
      role: 'user',
      content: content.trim(),
    );

    try {
      final userId = await dbHelper.insertMessage(userMessage);
      final savedUser = userMessage.copyWith(id: userId);
      if (!_isCurrentRequest(generation)) return;
      await memoryService.indexMessage(savedUser);
      if (!_isCurrentRequest(generation)) return;
      requestMessages.add(savedUser);

      state = state.copyWith(
        messages: List<Message>.of(requestMessages),
        currentSessionId: sessionId,
        isStreaming: true,
        error: null,
      );
    } catch (e) {
      if (!_isCurrentRequest(generation)) return;
      state = state.copyWith(
        error: 'Failed to save message',
        isStreaming: false,
      );
      Logger.e('ChatNotifier', 'Insert user message error: $e');
      return;
    }

    // 1.5 Extract memory from user input.
    try {
      await memoryService.extractFromUserInput(content);
    } catch (e) {
      Logger.e('ChatNotifier', 'Memory extraction error: $e');
    }
    if (!_isCurrentRequest(generation)) return;

    // 2. Create placeholder AI message
    final aiMessage = Message(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
    );
    state = state.copyWith(messages: [...state.messages, aiMessage]);
    var currentAiMessage = aiMessage;

    void publishAssistant(Message message, {bool? isStreaming}) {
      if (!_isCurrentRequest(generation)) return;
      final messages = List<Message>.of(state.messages);
      final index = messages.indexOf(currentAiMessage);
      if (index < 0) return;
      messages[index] = message;
      currentAiMessage = message;
      state = state.copyWith(messages: messages, isStreaming: isStreaming);
    }

    // 3. Stream AI response
    final rawBuffer = StringBuffer();
    final visibleBuffer = StringBuffer();
    final memoryTagFilter = MemoryTagStreamFilter();
    bool hasError = false;

    try {
      final memoryContext = await memoryService.buildContext(
        query: content,
        includeWorkoutHistory: selection.modules.any(
          (module) => module.id == 'fitness',
        ),
      );
      if (!_isCurrentRequest(generation)) return;
      unawaited(
        latencyService.recordEvent(
          sessionId: sessionId,
          provider: 'chat.memory_rag_context',
          latency: trace.elapsed,
        ),
      );
      final systemPrompt = AssistantPrompt.build(
        personality: ref.read(settingsProvider).personality,
        memoryContext: memoryContext,
        moduleGuidance: selection.guidance,
        voice: false,
      );

      final stream = llmService.sendWithTools(
        messages: ChatState(messages: requestMessages).apiMessages,
        systemPrompt: systemPrompt,
        tools: selection.tools,
        onTool: (name, args) async {
          if (!_isCurrentRequest(generation)) {
            throw const FormatException('请求已取消');
          }
          final result = await selection.invoke(
            name,
            args,
            sessionId: sessionId,
            turnId: userMessage.createdAt.toIso8601String(),
          );
          selection.ownerOf(name)?.afterTool(name, result);
          return result;
        },
      );

      var firstTokenRecorded = false;
      _streamSubscription = stream.listen(
        (token) {
          if (!_isCurrentRequest(generation)) return;
          rawBuffer.write(token);
          final visibleToken = memoryTagFilter.add(token);
          if (visibleToken.isEmpty) return;

          if (!firstTokenRecorded && visibleToken.trim().isNotEmpty) {
            firstTokenRecorded = true;
            unawaited(
              latencyService.recordEvent(
                sessionId: sessionId,
                provider: 'chat.llm_first_token',
                latency: trace.elapsed,
              ),
            );
          }
          visibleBuffer.write(visibleToken);
          publishAssistant(
            aiMessage.copyWith(content: visibleBuffer.toString()),
          );
        },
        onError: (error) {
          if (!_isCurrentRequest(generation)) return;
          hasError = true;
          unawaited(
            latencyService.recordEvent(
              sessionId: sessionId,
              provider: 'chat.total',
              latency: trace.elapsed,
              success: false,
              errorMessage: error.toString(),
            ),
          );
          state = state.copyWith(
            isStreaming: false,
            error: 'AI response error: $error',
          );
          Logger.e('ChatNotifier', 'Stream error: $error');
        },
        onDone: () async {
          if (!_isCurrentRequest(generation)) return;
          _streamSubscription = null;

          if (!hasError) {
            unawaited(
              latencyService.recordEvent(
                sessionId: sessionId,
                provider: 'chat.llm_stream_complete',
                latency: trace.elapsed,
              ),
            );
            final rawFinalContent = rawBuffer.toString();
            visibleBuffer.write(memoryTagFilter.close());
            final finalContent = LlmService.sanitizeAssistantContent(
              rawFinalContent,
            );
            final savedAi = aiMessage.copyWith(content: finalContent);
            var finalAi = savedAi;

            try {
              final aiId = await dbHelper.insertMessage(savedAi);
              final indexedAi = savedAi.copyWith(id: aiId);
              if (!_isCurrentRequest(generation)) return;
              await memoryService.indexMessage(indexedAi);
              if (!_isCurrentRequest(generation)) return;
              finalAi = indexedAi;
            } catch (e) {
              Logger.e('ChatNotifier', 'Insert AI message error: $e');
              if (!_isCurrentRequest(generation)) return;
            }

            publishAssistant(finalAi, isStreaming: false);
            final updatedMessages = [...requestMessages, finalAi];

            // Process memory tags from AI response
            try {
              await memoryService.processAiResponse(rawFinalContent);
            } catch (e) {
              Logger.e('ChatNotifier', 'Memory processing error: $e');
            }
            if (!_isCurrentRequest(generation)) return;

            unawaited(memoryService.distillSessionToRag(sessionId));
            unawaited(
              latencyService.recordEvent(
                sessionId: sessionId,
                provider: 'chat.total',
                latency: trace.elapsed,
              ),
            );

            // Check if summarization should be triggered
            try {
              if (_sessionStartTime != null) {
                final sessionDuration = DateTime.now().difference(
                  _sessionStartTime!,
                );
                if (memoryService.shouldTriggerSummary(
                  updatedMessages.length,
                  sessionDuration,
                )) {
                  Logger.d(
                    'ChatNotifier',
                    'Triggering conversation summary '
                        '(${updatedMessages.length} msgs, ${sessionDuration.inMinutes} min)',
                  );
                  // Reset timer so we don't trigger again immediately
                  _sessionStartTime = DateTime.now();
                  await memoryService.generateSummary(updatedMessages);
                }
              }
            } catch (e) {
              Logger.e('ChatNotifier', 'Summary generation error: $e');
            }
          }
        },
        cancelOnError: false,
      );
    } catch (e) {
      if (!_isCurrentRequest(generation)) return;
      unawaited(
        latencyService.recordEvent(
          sessionId: sessionId,
          provider: 'chat.total',
          latency: trace.elapsed,
          success: false,
          errorMessage: e.toString(),
        ),
      );
      state = state.copyWith(isStreaming: false, error: '$e');
    }
  }

  /// Start a new chat session.
  void startNewSession() {
    _cancelRequest();
    _sessionStartTime = null;
    state = const ChatState();
  }

  /// Load today's continuous conversation. The product treats chat as an
  /// ongoing daily thread rather than user-created ad-hoc sessions.
  Future<void> loadTodaySession() async {
    final sid = dailySessionId();
    if (state.currentSessionId == sid && state.messages.isNotEmpty) return;
    await loadHistory(sessionId: sid);
  }

  /// Clear all messages in the current session.
  void clearMessages() {
    _cancelRequest();
    state = state.copyWith(messages: [], isStreaming: false, error: null);
  }

  /// Load messages for the current or given session.
  Future<void> loadHistory({String? sessionId}) async {
    if (!ref.mounted) return;
    final dbHelper = ref.read(chatDatabaseProvider);
    final sid = sessionId ?? state.currentSessionId;
    _cancelRequest();
    final generation = _requestGeneration;
    state = state.copyWith(isStreaming: false);
    if (sid.isEmpty) {
      state = state.copyWith(messages: []);
      return;
    }

    try {
      final messages = await dbHelper.getMessages(sid);
      if (!_isCurrentRequest(generation)) return;
      state = state.copyWith(
        messages: messages,
        currentSessionId: sid,
        error: null,
      );
      // Reset session start time when loading history
      _sessionStartTime = DateTime.now();
    } catch (e) {
      Logger.e('ChatNotifier', 'Load history error: $e');
      if (!_isCurrentRequest(generation)) return;
      state = state.copyWith(error: 'Failed to load messages');
    }
  }

  /// Load the list of history sessions.
  Future<void> loadHistorySessions() async {
    if (!ref.mounted) return;
    final generation = ++_historyListGeneration;
    final dbHelper = ref.read(chatDatabaseProvider);
    try {
      final sessions = await dbHelper.getHistorySessions();
      if (!ref.mounted || generation != _historyListGeneration) return;
      state = state.copyWith(historySessions: sessions);
    } catch (e) {
      Logger.e('ChatNotifier', 'Load history sessions error: $e');
    }
  }

  /// Switch to a specific session.
  Future<void> switchToSession(String sessionId) async {
    _cancelRequest();
    _sessionStartTime = null;
    state = ChatState(currentSessionId: sessionId);
    await loadHistory();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String dailySessionId([DateTime? date]) {
    final d = date ?? DateTime.now();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return 'day_${d.year}$mm$dd';
  }

  /// Clear error from state.
  void clearError() {
    state = state.copyWith(clearError: true);
  }
}

extension _MessageWindow on List<Message> {
  List<Message> takeLast(int count) {
    if (length <= count) return this;
    return sublist(length - count);
  }
}
