import 'dart:async';

import 'package:ai_secretary/models/message.dart';
import 'package:ai_secretary/providers/settings_provider.dart';
import 'package:ai_secretary/services/ai_latency_service.dart';
import 'package:ai_secretary/services/llm_service.dart';
import 'package:ai_secretary/services/memory_service.dart';
import 'package:ai_secretary/services/tts_service.dart';

class ControlledMemoryService extends MemoryService {
  Completer<void>? userIndexGate;
  Completer<void>? assistantIndexGate;
  Completer<void>? contextGate;
  final userIndexEntered = Completer<void>();
  final assistantIndexEntered = Completer<void>();
  final contextEntered = Completer<void>();

  @override
  Future<void> indexMessage(Message message) async {
    final entered = message.isUser ? userIndexEntered : assistantIndexEntered;
    if (!entered.isCompleted) entered.complete();
    await (message.isUser ? userIndexGate : assistantIndexGate)?.future;
  }

  @override
  Future<String> buildContext({
    String? query,
    bool includeWorkoutHistory = false,
  }) async {
    if (!contextEntered.isCompleted) contextEntered.complete();
    await contextGate?.future;
    return '';
  }

  @override
  Future<void> extractFromUserInput(String userInput) async {}

  @override
  Future<void> processAiResponse(String aiResponse) async {}

  @override
  Future<int?> distillSessionToRag(String sessionId) async => null;

  @override
  bool shouldTriggerSummary(int messageCount, Duration sessionDuration) =>
      false;
}

/// Keep the real LLM tool loop, replacing only the external model request.
class ControlledLlmService extends LlmService {
  final requests = <List<Map<String, dynamic>>>[];
  final entered = Completer<void>();
  Completer<void>? responseGate;
  String response = '测试回复';

  @override
  Future<Map<String, dynamic>> requestToolTurn(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools,
  ) async {
    requests.add(messages.map(Map<String, dynamic>.from).toList());
    if (!entered.isCompleted) entered.complete();
    await responseGate?.future;
    return {'role': 'assistant', 'content': response};
  }
}

class ControlledLatencyService extends AiLatencyService {
  Completer<void>? asrGate;
  final asrEntered = Completer<void>();

  @override
  Future<void> recordEvent({
    String? sessionId,
    required String provider,
    required Duration latency,
    bool success = true,
    String? errorMessage,
    int? promptTokens,
    int? completionTokens,
  }) async {
    if (provider.startsWith('digital_voice.asr.')) {
      if (!asrEntered.isCompleted) asrEntered.complete();
      await asrGate?.future;
    }
  }
}

class ControlledSettingsNotifier extends SettingsNotifier {
  Completer<void>? speedGate;
  final speedEntered = Completer<void>();

  @override
  SettingsState build() => SettingsState.foundationInitial;

  @override
  Future<void> setTtsSpeed(double speed) async {
    if (!speedEntered.isCompleted) speedEntered.complete();
    await speedGate?.future;
    if (ref.mounted) state = state.copyWith(ttsSpeed: speed);
  }

  @override
  Future<void> setAsrEngine(AsrEngine engine) async {
    state = state.copyWith(asrEngine: engine);
  }
}

class ControlledTtsService extends TtsService {
  final spoken = <String>[];
  final entered = Completer<void>();
  Completer<void>? speechGate;

  @override
  Future<void> speak(String text, {String? emotion}) async {
    spoken.add(text);
    if (!entered.isCompleted) entered.complete();
    await speechGate?.future;
  }

  @override
  Future<void> stop() async {}

  @override
  void dispose() {}
}
