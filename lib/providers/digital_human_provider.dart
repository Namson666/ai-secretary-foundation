import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:io';
import 'package:record/record.dart';
import '../core/utils/logger.dart';
import 'chat_provider.dart';
import '../services/local_streaming_asr_service.dart';
import '../services/aliyun_realtime_asr_service.dart';
import '../core/assistant/assistant_module.dart';
import '../core/assistant/assistant_prompt.dart';
import '../core/assistant/speech_direction.dart';
import '../core/assistant/voice_speed_command.dart';
import '../core/search/web_search_module.dart';
import '../core/app_edition.dart';
import 'assistant_modules_provider.dart';
import '../services/minimax_file_asr_service.dart';
import '../services/ai_latency_service.dart';
import '../services/call_foreground_service.dart';
import '../services/llm_service.dart';
import '../services/memory_service.dart';
import '../services/tts_service.dart';
import 'settings_provider.dart';

final localStreamingAsrProvider = Provider<LocalStreamingAsrService>((ref) {
  final service = LocalStreamingAsrService();
  ref.onDispose(service.dispose);
  return service;
});

final aliyunRealtimeAsrProvider = Provider<AliyunRealtimeAsrService>((ref) {
  final service = AliyunRealtimeAsrService();
  ref.onDispose(service.dispose);
  return service;
});

final miniMaxFileAsrProvider = Provider<MiniMaxFileAsrService>((ref) {
  final service = MiniMaxFileAsrService();
  ref.onDispose(service.dispose);
  return service;
});

final digitalHumanTtsServiceProvider = Provider<TtsService>((ref) {
  final service = TtsService(
    voiceId: () => ref.read(settingsProvider).ttsVoiceId,
    model: () => ref.read(settingsProvider).ttsModel,
    speed: () => ref.read(settingsProvider).ttsSpeed,
  );
  ref.onDispose(service.dispose);
  return service;
});

final digitalHumanLlmServiceProvider = Provider<LlmService>((ref) {
  return LlmService(model: () => ref.read(settingsProvider).llmModel);
});

final digitalHumanMemoryServiceProvider = Provider<MemoryService>((ref) {
  return MemoryService(
    llmService: ref.read(digitalHumanLlmServiceProvider),
    includeHealthExtraction: !AppEdition.isFoundation,
  );
});

final digitalHumanLatencyServiceProvider = Provider<AiLatencyService>((ref) {
  return AiLatencyService();
});

/// 数字人情感类型枚举
enum EmotionType {
  happy,
  excited,
  sad,
  concerned,
  surprised,
  serious,
  gentle,
  neutral,
}

/// 数字人状态
class DigitalHumanState {
  final EmotionType emotion;
  final bool isSpeaking;
  final bool isInitialized;
  final String subtitleText;
  final bool isRecording;
  final bool isProcessing;
  final bool isCallActive;
  final String errorMessage;

  const DigitalHumanState({
    this.emotion = EmotionType.neutral,
    this.isSpeaking = false,
    this.isInitialized = false,
    this.subtitleText = '',
    this.isRecording = false,
    this.isProcessing = false,
    this.isCallActive = false,
    this.errorMessage = '',
  });

  DigitalHumanState copyWith({
    EmotionType? emotion,
    bool? isSpeaking,
    bool? isInitialized,
    String? subtitleText,
    bool? isRecording,
    bool? isProcessing,
    bool? isCallActive,
    String? errorMessage,
  }) {
    return DigitalHumanState(
      emotion: emotion ?? this.emotion,
      isSpeaking: isSpeaking ?? this.isSpeaking,
      isInitialized: isInitialized ?? this.isInitialized,
      subtitleText: subtitleText ?? this.subtitleText,
      isRecording: isRecording ?? this.isRecording,
      isProcessing: isProcessing ?? this.isProcessing,
      isCallActive: isCallActive ?? this.isCallActive,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// 数字人状态管理 + 语音交互流水线
class DigitalHumanNotifier extends Notifier<DigitalHumanState> {
  int _generation = 0;
  int _voiceSession = 0;
  int _callSession = 0;
  bool _startingVoice = false;
  bool _finishingVoice = false;
  bool _startingCall = false;
  bool _checkingCall = false;
  AsrEngine? _activeVoiceEngine;
  AsrEngine? _activeCallEngine;
  AssistantInputSnapshot? _voiceInputSnapshot;
  Future<void> Function()? _cancelVoiceCapture;
  Future<void> Function()? _cancelCallCapture;
  Future<void> Function()? _stopOutput;
  Future<void> _captureTeardown = Future<void>.value();
  Future<void>? _callTeardown;
  int? _pendingVoiceActionId;
  AssistantModule? _pendingVoiceModule;

  @override
  DigitalHumanState build() {
    final unsubscribe = CallForegroundService.onStopRequested(endCall);
    ref.onDispose(() {
      _generation++;
      _voiceSession++;
      _callSession++;
      unsubscribe();
      final hadCall = _startingCall || _activeCallEngine != null;
      final cancelVoice = _cancelVoiceCapture;
      final cancelCall = _cancelCallCapture;
      final stopOutput = _stopOutput;
      _cancelVoiceCapture = null;
      _cancelCallCapture = null;
      _stopOutput = null;
      _activeVoiceEngine = null;
      _activeCallEngine = null;
      _voiceInputSnapshot = null;
      _pendingVoiceActionId = null;
      _pendingVoiceModule = null;
      if (cancelVoice != null || cancelCall != null || hadCall) {
        unawaited(
          _queueCaptureTeardown(() async {
            await _release(cancelVoice);
            await _release(cancelCall);
            if (hadCall) await _release(CallForegroundService.stop);
          }),
        );
      }
      unawaited(_release(stopOutput));
    });
    return const DigitalHumanState();
  }

  bool _ownsVoiceInput(int session) => ref.mounted && session == _voiceSession;

  TtsService get _tts {
    final service = ref.read(digitalHumanTtsServiceProvider);
    _stopOutput = service.stop;
    return service;
  }

  static Future<void> _release(Future<void> Function()? release) async {
    try {
      await release?.call();
    } catch (error) {
      Logger.w('DigitalHuman', 'Resource cleanup failed: $error');
    }
  }

  // Both input modes use the same ASR services. Clearing their UI ownership
  // cannot permit a new capture until the previous microphone cleanup ends.
  Future<void> _queueCaptureTeardown(Future<void> Function() teardown) {
    final pending = _captureTeardown.then((_) => _release(teardown));
    _captureTeardown = pending;
    return pending;
  }

  Future<void> _awaitCaptureTeardown() async {
    while (true) {
      final pending = _captureTeardown;
      await pending;
      if (identical(pending, _captureTeardown)) return;
    }
  }

  void setInitialized() {
    state = state.copyWith(isInitialized: true);
  }

  void setEmotion(EmotionType emotion) {
    state = state.copyWith(emotion: emotion);
  }

  void setSpeaking(bool speaking) {
    state = state.copyWith(isSpeaking: speaking);
  }

  void setSubtitle(String text) {
    state = state.copyWith(subtitleText: text);
  }

  void reset() {
    unawaited(cancelVoiceInput());
    unawaited(endCall());
    stopCurrentOutput();
    state = const DigitalHumanState();
  }

  // ---------------------------------------------------------------------------
  // 语音交互流水线
  // ---------------------------------------------------------------------------

  /// 开始录音（会打断当前播放/生成）
  Future<void> startVoiceInput() async {
    if (!ref.mounted ||
        state.isRecording ||
        _startingVoice ||
        _finishingVoice ||
        state.isCallActive ||
        _startingCall) {
      return;
    }
    final input = AssistantInputSnapshot.capture(ref);
    stopCurrentOutput();
    final session = ++_voiceSession;
    final engine = ref.read(settingsProvider).asrEngine;
    _activeVoiceEngine = engine;
    _voiceInputSnapshot = input;
    _startingVoice = true;
    Future<void> Function()? cancelCapture;
    state = state.copyWith(
      isRecording: true,
      subtitleText: '准备语音识别...',
      errorMessage: '',
    );
    try {
      await _awaitCaptureTeardown();
      if (!_ownsVoiceInput(session) || _activeVoiceEngine != engine) return;
      if (engine == AsrEngine.minimaxFile) {
        final service = ref.read(miniMaxFileAsrProvider);
        _cancelVoiceCapture = cancelCapture = service.cancel;
        await service.start();
      } else if (engine == AsrEngine.aliyunFlash) {
        final service = ref.read(aliyunRealtimeAsrProvider);
        _cancelVoiceCapture = cancelCapture = service.stop;
        await service.start(
          onPartial: (text) {
            if (_ownsVoiceInput(session) && state.isRecording) {
              state = state.copyWith(subtitleText: text);
            }
          },
          onFinal: (text) {
            if (_ownsVoiceInput(session) && state.isRecording) {
              state = state.copyWith(subtitleText: text);
            }
          },
          onSpeechStart: () {},
        );
      } else {
        final service = ref.read(localStreamingAsrProvider);
        _cancelVoiceCapture = cancelCapture = service.cancel;
        await service.start((text) {
          if (_ownsVoiceInput(session) && state.isRecording) {
            state = state.copyWith(
              subtitleText: text.isEmpty ? '正在聆听...' : text,
            );
          }
        });
      }
      if (!_ownsVoiceInput(session) || _activeVoiceEngine != engine) {
        await _release(cancelCapture);
      }
    } catch (e) {
      Logger.e('DigitalHuman', 'ASR start failed: $e');
      if (_ownsVoiceInput(session)) {
        _activeVoiceEngine = null;
        _voiceInputSnapshot = null;
        _cancelVoiceCapture = null;
        final detail = e is StateError || engine == AsrEngine.aliyunFlash
            ? AliyunRealtimeAsrService.safeError(e)
            : e.toString();
        unawaited(
          _recordVoiceStage(
            ref.read(digitalHumanLatencyServiceProvider),
            sessionId: ChatNotifier.dailySessionId(),
            provider: 'digital_voice.asr.${engine.name}',
            latency: Duration.zero,
            success: false,
            errorMessage: detail,
          ),
        );
        state = state.copyWith(
          isRecording: false,
          subtitleText: '',
          errorMessage: '无法开始语音识别：$detail',
        );
      }
    } finally {
      _startingVoice = false;
    }
  }

  /// 取消录音（上划取消）
  Future<void> cancelVoiceInput() async {
    if (!ref.mounted || _activeVoiceEngine == null) return;
    final cancelCapture = _cancelVoiceCapture;
    _voiceSession++;
    _activeVoiceEngine = null;
    _voiceInputSnapshot = null;
    _cancelVoiceCapture = null;
    final teardown = _queueCaptureTeardown(() async {
      await cancelCapture?.call();
    });
    stopCurrentOutput();
    state = state.copyWith(isRecording: false, subtitleText: '');
    await teardown;
  }

  /// 停止实时识别，再交给既有的 LLM 和数字人播报流水线。
  Future<void> finishVoiceInput() async {
    if (!ref.mounted || !state.isRecording) return;
    if (_startingVoice) {
      await cancelVoiceInput();
      return;
    }
    final session = _voiceSession;
    final generation = _generation;
    final engine = _activeVoiceEngine;
    if (engine == null) return;
    final input =
        _voiceInputSnapshot ?? AssistantInputSnapshot.withoutContext(ref);
    bool current() => _ownsVoiceInput(session) && generation == _generation;
    _finishingVoice = true;
    state = state.copyWith(isRecording: false, isProcessing: true);
    final watch = Stopwatch()..start();
    try {
      final String text;
      try {
        text = (await switch (engine) {
          AsrEngine.local => ref.read(localStreamingAsrProvider).finish(),
          AsrEngine.aliyunFlash => ref.read(aliyunRealtimeAsrProvider).finish(),
          AsrEngine.minimaxFile => ref.read(miniMaxFileAsrProvider).finish(),
        }).trim();
      } finally {
        // A driver's finish may stop capture in its own finally block. Keep
        // ownership until that cleanup ends, even after UI cancellation.
        _finishingVoice = false;
      }
      watch.stop();
      if (!current()) return;
      await _recordVoiceStage(
        ref.read(digitalHumanLatencyServiceProvider),
        sessionId: ChatNotifier.dailySessionId(),
        provider: 'digital_voice.asr.${engine.name}',
        latency: watch.elapsed,
        success: text.isNotEmpty,
        errorMessage: text.isEmpty ? 'empty_asr_text' : null,
      );
      if (!current()) return;
      if (text.isEmpty) {
        state = state.copyWith(
          isProcessing: false,
          subtitleText: '',
          errorMessage: '没有识别到语音，请重试',
        );
        return;
      }
      _activeVoiceEngine = null;
      _voiceInputSnapshot = null;
      _cancelVoiceCapture = null;
      await _runTurn(inputText: text, input: input, fromVoice: true);
    } catch (e) {
      Logger.e('DigitalHuman', 'ASR finish failed: $e');
      if (current()) {
        final detail = engine == AsrEngine.aliyunFlash
            ? AliyunRealtimeAsrService.safeError(e)
            : e.toString();
        await _recordVoiceStage(
          ref.read(digitalHumanLatencyServiceProvider),
          sessionId: ChatNotifier.dailySessionId(),
          provider: 'digital_voice.asr.${engine.name}',
          latency: watch.elapsed,
          success: false,
          errorMessage: detail,
        );
        if (!current()) return;
        state = state.copyWith(
          isProcessing: false,
          subtitleText: '',
          errorMessage: '语音识别失败：$detail',
        );
      }
    } finally {
      if (_ownsVoiceInput(session)) {
        _activeVoiceEngine = null;
        _voiceInputSnapshot = null;
        _cancelVoiceCapture = null;
      }
    }
  }

  Future<void> startCall() async {
    if (!ref.mounted ||
        state.isCallActive ||
        _startingCall ||
        state.isRecording ||
        _startingVoice ||
        _finishingVoice ||
        _activeVoiceEngine != null) {
      return;
    }
    final engine = ref.read(settingsProvider).asrEngine;
    if (engine == AsrEngine.minimaxFile) {
      state = state.copyWith(errorMessage: 'MiniMax ASR 1.0 只支持录音后识别，请长按麦克风');
      return;
    }
    _startingCall = true;
    stopCurrentOutput();
    final session = ++_callSession;
    bool current() => ref.mounted && session == _callSession;
    final latencyService = ref.read(digitalHumanLatencyServiceProvider);
    Future<void> Function()? cancelCapture;
    final activeEngine = engine;
    AssistantInputSnapshot? utteranceInput;
    var aliyunReady = false;
    final asrWatch = Stopwatch()..start();
    void partial(String text) {
      if (current() && state.isCallActive && text.isNotEmpty) {
        state = state.copyWith(subtitleText: text);
      }
    }

    void speechStart() {
      if (!current() || !state.isCallActive) return;
      utteranceInput = AssistantInputSnapshot.capture(ref);
      asrWatch.reset();
      stopCurrentOutput();
      state = state.copyWith(subtitleText: '正在聆听...');
    }

    void finalText(String text) {
      if (!current() || !state.isCallActive) return;
      final captured = utteranceInput;
      utteranceInput = null;
      if (text.trim().isEmpty) return;
      final input = captured ?? AssistantInputSnapshot.withoutContext(ref);
      stopCurrentOutput();
      unawaited(
        _recordVoiceStage(
          latencyService,
          sessionId: ChatNotifier.dailySessionId(),
          provider: 'digital_voice.asr_utterance.${activeEngine.name}',
          latency: asrWatch.elapsed,
        ),
      );
      asrWatch.reset();
      unawaited(
        _runTurn(inputText: text.trim(), input: input, fromVoice: true),
      );
    }

    try {
      await _awaitCaptureTeardown();
      if (!current()) return;
      if (Platform.isAndroid) {
        final permissionProbe = AudioRecorder();
        try {
          if (!await permissionProbe.hasPermission()) {
            throw StateError('请先允许使用麦克风');
          }
        } finally {
          await permissionProbe.dispose();
        }
      }
      if (!current()) return;
      await CallForegroundService.start();
      if (!current()) {
        await CallForegroundService.stop();
        return;
      }
      state = state.copyWith(
        isCallActive: true,
        subtitleText: '正在聆听...',
        errorMessage: '',
      );
      _activeCallEngine = engine;
      if (engine == AsrEngine.aliyunFlash) {
        try {
          final service = ref.read(aliyunRealtimeAsrProvider);
          _cancelCallCapture = cancelCapture = service.stop;
          await service.start(
            onPartial: partial,
            onFinal: finalText,
            onSpeechStart: speechStart,
            onError: (error) {
              if (aliyunReady && current() && state.isCallActive) {
                final detail = AliyunRealtimeAsrService.safeError(error);
                unawaited(
                  _recordVoiceStage(
                    latencyService,
                    sessionId: ChatNotifier.dailySessionId(),
                    provider: 'digital_voice.asr_utterance.aliyunFlash',
                    latency: asrWatch.elapsed,
                    success: false,
                    errorMessage: detail,
                  ),
                );
                state = state.copyWith(errorMessage: '阿里实时识别中断：$detail');
                unawaited(endCall());
              }
            },
          );
          if (!current()) {
            await _release(cancelCapture);
            return;
          }
          aliyunReady = true;
          return;
        } catch (error) {
          Logger.w(
            'DigitalHuman',
            'Aliyun ASR unavailable: ${AliyunRealtimeAsrService.safeError(error)}',
          );
          rethrow;
        }
      }
      final service = ref.read(localStreamingAsrProvider);
      _cancelCallCapture = cancelCapture = service.cancel;
      await service.startConversation(
        onPartial: partial,
        onUtterance: finalText,
        onSpeechStart: speechStart,
      );
      if (!current()) await _release(cancelCapture);
    } catch (error) {
      if (engine == AsrEngine.aliyunFlash) {
        unawaited(
          _recordVoiceStage(
            latencyService,
            sessionId: ChatNotifier.dailySessionId(),
            provider: 'digital_voice.asr.aliyunFlash',
            latency: asrWatch.elapsed,
            success: false,
            errorMessage: AliyunRealtimeAsrService.safeError(error),
          ),
        );
      }
      Logger.e(
        'DigitalHuman',
        'Call start failed: ${engine == AsrEngine.aliyunFlash ? AliyunRealtimeAsrService.safeError(error) : error}',
      );
      if (current()) {
        state = state.copyWith(
          isCallActive: false,
          errorMessage:
              '无法开始实时通话：${engine == AsrEngine.aliyunFlash ? AliyunRealtimeAsrService.safeError(error) : error}',
        );
        _activeCallEngine = null;
        _cancelCallCapture = null;
      }
      await _release(cancelCapture);
      await CallForegroundService.stop();
    } finally {
      _startingCall = false;
    }
  }

  Future<void> endCall() async {
    if (!ref.mounted) return;
    final hadCall = state.isCallActive || _startingCall;
    _callSession++;
    final pending = _callTeardown;
    if (pending != null) {
      await pending;
      return;
    }
    if (!hadCall) return;
    final cancelCapture = _cancelCallCapture;
    _cancelCallCapture = null;
    _activeCallEngine = null;
    _pendingVoiceActionId = null;
    _pendingVoiceModule = null;
    final teardown = _queueCaptureTeardown(() async {
      try {
        await cancelCapture?.call();
      } finally {
        await CallForegroundService.stop();
      }
    });
    _callTeardown = teardown;
    stopCurrentOutput();
    state = state.copyWith(isCallActive: false, subtitleText: '');
    try {
      await teardown;
    } finally {
      if (identical(_callTeardown, teardown)) _callTeardown = null;
    }
  }

  Future<void> resumeCallIfNeeded() async {
    if (!ref.mounted || !state.isCallActive || _checkingCall || _startingCall) {
      return;
    }
    _checkingCall = true;
    final session = _callSession;
    try {
      final engine = _activeCallEngine;
      final listening = engine == AsrEngine.aliyunFlash
          ? await ref.read(aliyunRealtimeAsrProvider).isCapturing
          : await ref.read(localStreamingAsrProvider).isCapturing;
      if (!ref.mounted ||
          session != _callSession ||
          !state.isCallActive ||
          (listening && engine == ref.read(settingsProvider).asrEngine)) {
        return;
      }
      await endCall();
      if (!ref.mounted || _callSession != session + 1) return;
      await startCall();
    } finally {
      _checkingCall = false;
    }
  }

  /// Typed input shares the avatar's memory, tools, TTS and lip-sync pipeline.
  Future<void> sendTextInput(String text) async {
    if (!ref.mounted) return;
    if (text.trim().isEmpty || state.isProcessing || state.isRecording) return;
    final input = AssistantInputSnapshot.capture(ref);
    stopCurrentOutput();
    await _runTurn(inputText: text.trim(), input: input);
  }

  Future<void> _runTurn({
    required String inputText,
    required AssistantInputSnapshot input,
    bool fromVoice = false,
  }) async {
    final generation = ++_generation;
    bool cancelled() => !ref.mounted || generation != _generation;
    final speedCommand = VoiceSpeedCommands.parse(inputText);
    if (speedCommand != null) {
      final settings = ref.read(settingsProvider);
      final next = VoiceSpeedCommands.apply(speedCommand, settings.ttsSpeed);
      await ref.read(settingsProvider.notifier).setTtsSpeed(next);
      if (cancelled()) return;
      state = state.copyWith(
        isProcessing: false,
        subtitleText: '',
        errorMessage: '',
      );
      state = state.copyWith(isSpeaking: true);
      try {
        await _tts.speak(
          speedCommand == VoiceSpeedCommand.normal ? '好，恢复正常语速。' : '好。',
        );
      } catch (error) {
        if (!cancelled()) {
          state = state.copyWith(errorMessage: '语速已调整，但语音反馈失败：$error');
        }
      } finally {
        if (!cancelled()) state = state.copyWith(isSpeaking: false);
      }
      return;
    }
    final stagePrefix = fromVoice ? 'digital_voice' : 'digital_text';
    state = state.copyWith(
      isRecording: false,
      isProcessing: true,
      errorMessage: '',
    );
    final totalWatch = Stopwatch()..start();
    final ttsService = _tts;
    final memoryService = ref.read(digitalHumanMemoryServiceProvider);
    final llmService = ref.read(digitalHumanLlmServiceProvider);
    final latencyService = ref.read(digitalHumanLatencyServiceProvider);
    final sessionId = ChatNotifier.dailySessionId();
    if (fromVoice && _pendingVoiceActionId != null) {
      final module = _pendingVoiceModule;
      final available =
          module != null &&
          input.profile.allowsModule(module.id) &&
          input.registry.modules.contains(module);
      final decision = available ? module.voiceDecision(inputText) : null;
      final actionId = _pendingVoiceActionId;
      _pendingVoiceActionId = null;
      _pendingVoiceModule = null;
      if (decision != null && actionId != null && module != null) {
        try {
          final receipt = await module.decide(
            actionId,
            decision,
            sessionId: sessionId,
          );
          await module.afterAction();
          await memoryService.persistVoiceTurn(
            sessionId: sessionId,
            userText: inputText,
            assistantRawContent: receipt,
            extractUserMemory: false,
          );
          if (cancelled()) return;
          state = state.copyWith(
            isProcessing: false,
            isSpeaking: true,
            subtitleText: receipt,
          );
          await ttsService.speak(receipt);
          if (!cancelled()) state = state.copyWith(isSpeaking: false);
        } catch (error) {
          if (!cancelled()) {
            state = state.copyWith(
              isProcessing: false,
              isSpeaking: false,
              errorMessage: '操作未完成：$error',
            );
          }
        }
        return;
      }
    }
    final selectedModel = llmService.selectedModel;
    Map<String, dynamic>? proposedAction;
    AssistantModule? proposedModule;
    Timer? searchCueTimer;
    var searchCueSpoken = false;
    var voiceSucceeded = false;
    String? voiceError;
    var failureStage = '对话';

    try {
      final text = inputText;
      final selection = input.select(text);

      // 显示用户说的话
      failureStage = '对话';
      state = state.copyWith(subtitleText: text);
      final contextWatch = Stopwatch()..start();
      await memoryService.extractFromUserInput(text);
      if (cancelled()) return;
      final memoryContext = await memoryService.buildContext(
        query: text,
        includeWorkoutHistory: selection.modules.any(
          (module) => module.id == 'fitness',
        ),
      );
      if (cancelled()) return;
      final apiMessages = await memoryService.buildApiMessagesForSession(
        sessionId: sessionId,
        pendingUserText: text,
      );
      contextWatch.stop();
      Logger.d(
        'DigitalHuman',
        'voice_stage=memory_context ms=${contextWatch.elapsedMilliseconds} chars=${memoryContext.length}',
      );
      await _recordVoiceStage(
        latencyService,
        sessionId: sessionId,
        provider: '$stagePrefix.memory_context',
        latency: contextWatch.elapsed,
      );

      // 3. LLM 获取简短回复
      if (cancelled()) return;
      failureStage = '模型回复';
      state = state.copyWith(subtitleText: '思考中...');
      final llmWatch = Stopwatch()..start();
      final rawResponse = await llmService
          .sendWithTools(
            messages: apiMessages,
            systemPrompt: AssistantPrompt.build(
              personality: ref.read(settingsProvider).personality,
              memoryContext: memoryContext,
              moduleGuidance: selection.guidance,
              voice: true,
            ),
            tools: selection.tools,
            onTool: (name, args) async {
              if (cancelled()) return {'error': '用户已取消'};
              final owner = selection.ownerOf(name);
              if (owner?.isProposal(name) == true && proposedAction != null) {
                return {'error': '本轮只能提出一项待确认操作，请先确认或取消当前操作'};
              }
              if (name == WebSearchModule.toolName && !searchCueSpoken) {
                searchCueTimer?.cancel();
                searchCueTimer = Timer(const Duration(seconds: 2), () {
                  if (cancelled() || !state.isProcessing) return;
                  searchCueSpoken = true;
                  const cue = '我查一下。';
                  state = state.copyWith(isSpeaking: true, subtitleText: cue);
                  unawaited(
                    ttsService
                        .speak(cue)
                        .then((_) {
                          if (!cancelled() && state.isProcessing) {
                            state = state.copyWith(isSpeaking: false);
                          }
                        })
                        .catchError((Object error) {
                          Logger.w(
                            'DigitalHuman',
                            'Search cue unavailable: $error',
                          );
                        }),
                  );
                });
              }
              Map<String, dynamic> result;
              try {
                result = await selection.invoke(
                  name,
                  args,
                  sessionId: sessionId,
                  turnId: '$stagePrefix-$generation-${totalWatch.hashCode}',
                );
              } finally {
                if (name == WebSearchModule.toolName) searchCueTimer?.cancel();
              }
              owner?.afterTool(name, result);
              if (owner?.isProposal(name) == true &&
                  result['action_id'] is int) {
                proposedAction = result;
                proposedModule = owner;
              }
              return result;
            },
          )
          .join();
      final response = proposedAction == null
          ? LlmService.sanitizeAssistantContent(rawResponse)
          : proposedModule!.describeProposal(proposedAction!);
      searchCueTimer?.cancel();
      llmWatch.stop();
      Logger.d(
        'DigitalHuman',
        'voice_stage=llm ms=${llmWatch.elapsedMilliseconds} chars=${response.length}',
      );
      await _recordVoiceStage(
        latencyService,
        sessionId: sessionId,
        provider: '$stagePrefix.llm.$selectedModel',
        latency: llmWatch.elapsed,
        success: response.isNotEmpty,
        errorMessage: response.isEmpty ? 'empty_llm_response' : null,
      );
      if (cancelled() || response.isEmpty) {
        voiceError = cancelled() ? 'cancelled' : 'empty_llm_response';
        if (!cancelled()) {
          state = state.copyWith(
            isProcessing: false,
            subtitleText: '',
            errorMessage: '暂时没有收到回复，请重试',
          );
        }
        return;
      }

      // 4. 显示回复字幕
      state = state.copyWith(subtitleText: response);
      try {
        await memoryService.persistVoiceTurn(
          sessionId: sessionId,
          userText: text,
          assistantRawContent: proposedAction == null ? rawResponse : response,
          extractUserMemory: false,
        );
      } catch (e) {
        Logger.e('DigitalHuman', 'Persist voice turn error: $e');
      }

      // 5. TTS 语音播报
      if (cancelled()) return;
      failureStage = '语音播报';
      await ttsService.stop();
      if (cancelled()) return;
      final selectedTtsModel = ref.read(settingsProvider).ttsModel;
      state = state.copyWith(
        isSpeaking: true,
        isProcessing: false,
        subtitleText: '合成语音中...',
      );
      final ttsWatch = Stopwatch()..start();
      try {
        await ttsService.speak(
          response,
          emotion: proposedAction == null
              ? SpeechDirection.emotionFrom(rawResponse)
              : null,
        );
        if (proposedAction != null && fromVoice && !cancelled()) {
          _pendingVoiceActionId = proposedAction!['action_id'] as int;
          _pendingVoiceModule = proposedModule;
        }
        ttsWatch.stop();
        Logger.d(
          'DigitalHuman',
          'voice_stage=tts_playback ms=${ttsWatch.elapsedMilliseconds}',
        );
        await _recordVoiceStage(
          latencyService,
          sessionId: sessionId,
          provider: '$stagePrefix.tts_playback.$selectedTtsModel',
          latency: ttsWatch.elapsed,
        );
      } catch (e) {
        ttsWatch.stop();
        voiceError = e.toString();
        await _recordVoiceStage(
          latencyService,
          sessionId: sessionId,
          provider: '$stagePrefix.tts_playback.$selectedTtsModel',
          latency: ttsWatch.elapsed,
          success: false,
          errorMessage: e.toString(),
        );
        Logger.e('DigitalHuman', 'TTS playback error: $e');
        if (!cancelled()) {
          state = state.copyWith(errorMessage: '语音播报失败，请检查网络后重试');
        }
      }
      if (!cancelled()) {
        state = state.copyWith(isSpeaking: false, subtitleText: response);
        voiceSucceeded = voiceError == null;
      }
    } catch (e) {
      voiceError = e.toString();
      Logger.e('DigitalHuman', 'Voice pipeline error: $e');
      if (failureStage == '模型回复') {
        await _recordVoiceStage(
          latencyService,
          sessionId: sessionId,
          provider: '$stagePrefix.llm.$selectedModel',
          latency: totalWatch.elapsed,
          success: false,
          errorMessage: e.toString(),
        );
      }
      if (!cancelled()) {
        final detail = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
        state = state.copyWith(
          isRecording: false,
          isProcessing: false,
          isSpeaking: false,
          subtitleText: '',
          errorMessage: '$failureStage失败：$detail',
        );
      }
    } finally {
      searchCueTimer?.cancel();
      totalWatch.stop();
      Logger.d(
        'DigitalHuman',
        'voice_stage=total ms=${totalWatch.elapsedMilliseconds}',
      );
      await _recordVoiceStage(
        latencyService,
        sessionId: sessionId,
        provider: '$stagePrefix.total',
        latency: totalWatch.elapsed,
        success: voiceSucceeded && !cancelled(),
        errorMessage: cancelled() ? 'cancelled' : voiceError,
      );
    }
  }

  /// 打断当前语音/TTS
  void stopCurrentOutput() {
    if (!ref.mounted) return;
    _generation++;
    unawaited(_release(_tts.stop));
    state = state.copyWith(
      isSpeaking: false,
      isProcessing: false,
      subtitleText: '',
    );
  }

  Future<void> _recordVoiceStage(
    AiLatencyService latencyService, {
    required String sessionId,
    required String provider,
    required Duration latency,
    bool success = true,
    String? errorMessage,
  }) async {
    await latencyService.recordEvent(
      sessionId: sessionId,
      provider: provider,
      latency: latency,
      success: success,
      errorMessage: errorMessage,
    );
  }
}

/// DigitalHumanState 的 Riverpod Provider
final digitalHumanProvider =
    NotifierProvider<DigitalHumanNotifier, DigitalHumanState>(
      DigitalHumanNotifier.new,
    );
