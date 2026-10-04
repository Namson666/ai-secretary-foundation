import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/database_helper.dart';
import '../core/assistant/assistant_module.dart';
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

  /// Track session start time for summary trigger logic.
  DateTime? _sessionStartTime;

  @override
  ChatState build() {
    ref.onDispose(() {
      _streamSubscription?.cancel();
    });
    return const ChatState();
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Send a plain-text message.
  Future<void> sendMessage(String content) async {
    if (content.trim().isEmpty) return;
    if (state.isStreaming) return;
    final generation = ++_requestGeneration;
    state = state.copyWith(isStreaming: true, clearError: true);

    final llmService = ref.read(llmServiceProvider);
    final memoryService = ref.read(memoryServiceProvider);
    final latencyService = ref.read(aiLatencyServiceProvider);
    final dbHelper = DatabaseHelper.instance;

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
      await memoryService.indexMessage(savedUser);

      state = state.copyWith(
        messages: [...state.messages, savedUser],
        currentSessionId: sessionId,
        isStreaming: true,
        error: null,
      );
    } catch (e) {
      state = state.copyWith(
        error: 'Failed to save message',
        isStreaming: false,
      );
      Logger.e('ChatNotifier', 'Insert user message error: $e');
      return;
    }

    // 1.5 Extract memory from user input (fire-and-forget)
    try {
      await memoryService.extractFromUserInput(content);
    } catch (e) {
      Logger.e('ChatNotifier', 'Memory extraction error: $e');
    }

    // 2. Create placeholder AI message
    final aiMessage = Message(
      sessionId: sessionId,
      role: 'assistant',
      content: '',
    );
    state = state.copyWith(messages: [...state.messages, aiMessage]);

    // 3. Stream AI response
    final rawBuffer = StringBuffer();
    final visibleBuffer = StringBuffer();
    final memoryTagFilter = MemoryTagStreamFilter();
    bool hasError = false;

    try {
      final modules = ref.read(assistantModuleRegistryProvider).select(content);
      final memoryContext = await memoryService.buildContext(
        query: content,
        includeWorkoutHistory: modules.any((module) => module.id == 'fitness'),
      );
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
        moduleGuidance: AssistantModuleRegistry.guidanceFor(modules),
        voice: false,
      );

      final stream = llmService.sendWithTools(
        messages: state.apiMessages,
        systemPrompt: systemPrompt,
        tools: AssistantModuleRegistry.toolsFor(modules),
        onTool: (name, args) async {
          if (!ref.mounted || generation != _requestGeneration) {
            throw const FormatException('请求已取消');
          }
          final result = await AssistantModuleRegistry.invoke(
            modules,
            name,
            args,
            sessionId: sessionId,
            turnId: userMessage.createdAt.toIso8601String(),
          );
          AssistantModuleRegistry.ownerOf(
            modules,
            name,
          )?.afterTool(name, result);
          return result;
        },
      );

      var firstTokenRecorded = false;
      _streamSubscription = stream.listen(
        (token) {
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
          final updatedMessages = List<Message>.from(state.messages);
          updatedMessages[updatedMessages.length - 1] = aiMessage.copyWith(
            content: visibleBuffer.toString(),
          );
          state = state.copyWith(messages: updatedMessages);
        },
        onError: (error) {
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
            final updatedMessages = List<Message>.from(state.messages);
            final savedAi = aiMessage.copyWith(content: finalContent);

            try {
              final aiId = await dbHelper.insertMessage(savedAi);
              final indexedAi = savedAi.copyWith(id: aiId);
              await memoryService.indexMessage(indexedAi);
              updatedMessages[updatedMessages.length - 1] = indexedAi;
            } catch (e) {
              Logger.e('ChatNotifier', 'Insert AI message error: $e');
              updatedMessages[updatedMessages.length - 1] = savedAi;
            }

            state = state.copyWith(
              messages: updatedMessages,
              isStreaming: false,
            );

            // Process memory tags from AI response
            try {
              await memoryService.processAiResponse(rawFinalContent);
            } catch (e) {
              Logger.e('ChatNotifier', 'Memory processing error: $e');
            }

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
    _requestGeneration++;
    _streamSubscription?.cancel();
    _streamSubscription = null;
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
    _requestGeneration++;
    _streamSubscription?.cancel();
    _streamSubscription = null;
    state = state.copyWith(messages: [], isStreaming: false, error: null);
  }

  /// Load messages for the current or given session.
  Future<void> loadHistory({String? sessionId}) async {
    final dbHelper = DatabaseHelper.instance;
    final sid = sessionId ?? state.currentSessionId;
    if (sid.isEmpty) {
      state = state.copyWith(messages: []);
      return;
    }

    try {
      final messages = await dbHelper.getMessages(sid);
      state = state.copyWith(
        messages: messages,
        currentSessionId: sid,
        error: null,
      );
      // Reset session start time when loading history
      _sessionStartTime = DateTime.now();
    } catch (e) {
      Logger.e('ChatNotifier', 'Load history error: $e');
      state = state.copyWith(error: 'Failed to load messages');
    }
  }

  /// Load the list of history sessions.
  Future<void> loadHistorySessions() async {
    final dbHelper = DatabaseHelper.instance;
    try {
      final sessions = await dbHelper.getHistorySessions();
      state = state.copyWith(historySessions: sessions);
    } catch (e) {
      Logger.e('ChatNotifier', 'Load history sessions error: $e');
    }
  }

  /// Switch to a specific session.
  Future<void> switchToSession(String sessionId) async {
    _requestGeneration++;
    _streamSubscription?.cancel();
    _streamSubscription = null;
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
