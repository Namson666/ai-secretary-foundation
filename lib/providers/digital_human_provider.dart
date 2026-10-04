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
  bool _startingCall = false;
  bool _checkingCall = false;
  AsrEngine? _activeCallEngine;
  int? _pendingVoiceActionId;
  AssistantModule? _pendingVoiceModule;

  @override
  DigitalHumanState build() {
    CallForegroundService.onStopRequested(endCall);
    return const DigitalHumanState();
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
    unawaited(endCall());
    stopCurrentOutput();
    state = const DigitalHumanState();
  }

  // ---------------------------------------------------------------------------
  // 语音交互流水线
  // ---------------------------------------------------------------------------

  /// 开始录音（会打断当前播放/生成）
  Future<void> startVoiceInput() async {
    if (state.isRecording) return;
    stopCurrentOutput();
    final session = ++_voiceSession;
    state = state.copyWith(
      isRecording: true,
      subtitleText: '准备语音识别...',
      errorMessage: '',
    );
    try {
      final engine = ref.read(settingsProvider).asrEngine;
      if (engine == AsrEngine.minimaxFile) {
        await ref.read(miniMaxFileAsrProvider).start();
      } else if (engine == AsrEngine.aliyunFlash) {
        await ref
            .read(aliyunRealtimeAsrProvider)
            .start(
              onPartial: (text) {
                if (session == _voiceSession && state.isRecording) {
                  state = state.copyWith(subtitleText: text);
                }
              },
              onFinal: (text) {
                if (session == _voiceSession && state.isRecording) {
                  state = state.copyWith(subtitleText: text);
                }
              },
              onSpeechStart: () {},
            );
      } else {
        await ref.read(localStreamingAsrProvider).start((text) {
          if (session == _voiceSession && state.isRecording) {
            state = state.copyWith(
              subtitleText: text.isEmpty ? '正在聆听...' : text,
            );
          }
        });
      }
    } catch (e) {
      Logger.e('DigitalHuman', 'ASR start failed: $e');
      if (session == _voiceSession) {
        final detail =
            e is StateError ||
                ref.read(settingsProvider).asrEngine == AsrEngine.aliyunFlash
            ? AliyunRealtimeAsrService.safeError(e)
            : e.toString();
        unawaited(
          _recordVoiceStage(
            ref.read(digitalHumanLatencyServiceProvider),
            sessionId: ChatNotifier.dailySessionId(),
            provider:
                'digital_voice.asr.${ref.read(settingsProvider).asrEngine.name}',
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
    }
  }

  /// 取消录音（上划取消）
  Future<void> cancelVoiceInput() async {
    _voiceSession++;
    state = state.copyWith(isRecording: false, subtitleText: '');
    await ref.read(localStreamingAsrProvider).cancel();
    await ref.read(aliyunRealtimeAsrProvider).stop();
    await ref.read(miniMaxFileAsrProvider).cancel();
  }

  /// 停止实时识别，再交给既有的 LLM 和数字人播报流水线。
  Future<void> finishVoiceInput() async {
    if (!state.isRecording) return;
    final session = _voiceSession;
    final engine = ref.read(settingsProvider).asrEngine;
    state = state.copyWith(isRecording: false, isProcessing: true);
    final watch = Stopwatch()..start();
    try {
      final text = (await switch (engine) {
        AsrEngine.local => ref.read(localStreamingAsrProvider).finish(),
        AsrEngine.aliyunFlash => ref.read(aliyunRealtimeAsrProvider).finish(),
        AsrEngine.minimaxFile => ref.read(miniMaxFileAsrProvider).finish(),
      }).trim();
      watch.stop();
      if (session != _voiceSession) return;
      await _recordVoiceStage(
        ref.read(digitalHumanLatencyServiceProvider),
        sessionId: ChatNotifier.dailySessionId(),
        provider: 'digital_voice.asr.${engine.name}',
        latency: watch.elapsed,
        success: text.isNotEmpty,
        errorMessage: text.isEmpty ? 'empty_asr_text' : null,
      );
      if (text.isEmpty) {
        state = state.copyWith(
          isProcessing: false,
          subtitleText: '',
          errorMessage: '没有识别到语音，请重试',
        );
        return;
      }
      await _runTurn(inputText: text, fromVoice: true);
    } catch (e) {
      Logger.e('DigitalHuman', 'ASR finish failed: $e');
      if (session == _voiceSession) {
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
        state = state.copyWith(
          isProcessing: false,
          subtitleText: '',
          errorMessage: '语音识别失败：$detail',
        );
      }
    }
  }

  Future<void> startCall() async {
    if (state.isCallActive || _startingCall) return;
    final engine = ref.read(settingsProvider).asrEngine;
    if (engine == AsrEngine.minimaxFile) {
      state = state.copyWith(errorMessage: 'MiniMax ASR 1.0 只支持录音后识别，请长按麦克风');
      return;
    }
    _startingCall = true;
    stopCurrentOutput();
    final session = ++_callSession;
    final activeEngine = engine;
    var aliyunReady = false;
    final asrWatch = Stopwatch()..start();
    void partial(String text) {
      if (session == _callSession && state.isCallActive && text.isNotEmpty) {
        state = state.copyWith(subtitleText: text);
      }
    }

    void speechStart() {
      if (session != _callSession || !state.isCallActive) return;
      asrWatch.reset();
      if (state.isSpeaking || state.isProcessing) stopCurrentOutput();
      state = state.copyWith(subtitleText: '正在聆听...');
    }

    void finalText(String text) {
      if (session != _callSession ||
          !state.isCallActive ||
          text.trim().isEmpty) {
        return;
      }
      stopCurrentOutput();
      unawaited(
        _recordVoiceStage(
          ref.read(digitalHumanLatencyServiceProvider),
          sessionId: ChatNotifier.dailySessionId(),
          provider: 'digital_voice.asr_utterance.${activeEngine.name}',
          latency: asrWatch.elapsed,
        ),
      );
      asrWatch.reset();
      unawaited(_runTurn(inputText: text.trim(), fromVoice: true));
    }

    try {
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
      if (session != _callSession) return;
      await CallForegroundService.start();
      if (session != _callSession) {
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
          await ref
              .read(aliyunRealtimeAsrProvider)
              .start(
                onPartial: partial,
                onFinal: finalText,
                onSpeechStart: speechStart,
                onError: (error) {
                  if (aliyunReady &&
                      session == _callSession &&
                      state.isCallActive) {
                    final detail = AliyunRealtimeAsrService.safeError(error);
                    unawaited(
                      _recordVoiceStage(
                        ref.read(digitalHumanLatencyServiceProvider),
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
      await ref
          .read(localStreamingAsrProvider)
          .startConversation(
            onPartial: partial,
            onUtterance: finalText,
            onSpeechStart: speechStart,
          );
    } catch (error) {
      if (engine == AsrEngine.aliyunFlash) {
        unawaited(
          _recordVoiceStage(
            ref.read(digitalHumanLatencyServiceProvider),
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
      if (session == _callSession) {
        state = state.copyWith(
          isCallActive: false,
          errorMessage:
              '无法开始实时通话：${engine == AsrEngine.aliyunFlash ? AliyunRealtimeAsrService.safeError(error) : error}',
        );
      }
      _activeCallEngine = null;
      await CallForegroundService.stop();
    } finally {
      _startingCall = false;
    }
  }

  Future<void> endCall() async {
    if (!state.isCallActive && !_startingCall) return;
    _callSession++;
    _activeCallEngine = null;
    _pendingVoiceActionId = null;
    _pendingVoiceModule = null;
    stopCurrentOutput();
    state = state.copyWith(isCallActive: false, subtitleText: '');
    try {
      await ref.read(localStreamingAsrProvider).cancel();
      await ref.read(aliyunRealtimeAsrProvider).stop();
    } finally {
      await CallForegroundService.stop();
    }
  }

  Future<void> resumeCallIfNeeded() async {
    if (!state.isCallActive || _checkingCall || _startingCall) return;
    _checkingCall = true;
    try {
      final engine = _activeCallEngine;
      final listening = engine == AsrEngine.aliyunFlash
          ? await ref.read(aliyunRealtimeAsrProvider).isCapturing
          : await ref.read(localStreamingAsrProvider).isCapturing;
      if (!state.isCallActive ||
          (listening && engine == ref.read(settingsProvider).asrEngine)) {
        return;
      }
      await endCall();
      await startCall();
    } finally {
      _checkingCall = false;
    }
  }

  /// Typed input shares the avatar's memory, tools, TTS and lip-sync pipeline.
  Future<void> sendTextInput(String text) async {
    if (text.trim().isEmpty || state.isProcessing || state.isRecording) return;
    stopCurrentOutput();
    await _runTurn(inputText: text.trim());
  }

  Future<void> _runTurn({
    required String inputText,
    bool fromVoice = false,
  }) async {
    final speedCommand = VoiceSpeedCommands.parse(inputText);
    if (speedCommand != null) {
      final settings = ref.read(settingsProvider);
      final next = VoiceSpeedCommands.apply(speedCommand, settings.ttsSpeed);
      await ref.read(settingsProvider.notifier).setTtsSpeed(next);
      state = state.copyWith(
        isProcessing: false,
        subtitleText: '',
        errorMessage: '',
      );
      state = state.copyWith(isSpeaking: true);
      try {
        await ref
            .read(digitalHumanTtsServiceProvider)
            .speak(
              speedCommand == VoiceSpeedCommand.normal ? '好，恢复正常语速。' : '好。',
            );
      } catch (error) {
        state = state.copyWith(errorMessage: '语速已调整，但语音反馈失败：$error');
      } finally {
        state = state.copyWith(isSpeaking: false);
      }
      return;
    }
    final generation = ++_generation;
    bool cancelled() => generation != _generation;
    final stagePrefix = fromVoice ? 'digital_voice' : 'digital_text';
    state = state.copyWith(
      isRecording: false,
      isProcessing: true,
      errorMessage: '',
    );
    final totalWatch = Stopwatch()..start();
    final ttsService = ref.read(digitalHumanTtsServiceProvider);
    final memoryService = ref.read(digitalHumanMemoryServiceProvider);
    final llmService = ref.read(digitalHumanLlmServiceProvider);
    final latencyService = ref.read(digitalHumanLatencyServiceProvider);
    final sessionId = ChatNotifier.dailySessionId();
    if (fromVoice && _pendingVoiceActionId != null) {
      final module = _pendingVoiceModule;
      final decision = module?.voiceDecision(inputText);
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
              errorMessage: '训练操作未完成：$error',
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

      // 显示用户说的话
      failureStage = '对话';
      state = state.copyWith(subtitleText: text);
      final contextWatch = Stopwatch()..start();
      await memoryService.extractFromUserInput(text);
      final modules = ref.read(assistantModuleRegistryProvider).select(text);
      final memoryContext = await memoryService.buildContext(
        query: text,
        includeWorkoutHistory: modules.any((module) => module.id == 'fitness'),
      );
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
              moduleGuidance: AssistantModuleRegistry.guidanceFor(modules),
              voice: true,
            ),
            tools: AssistantModuleRegistry.toolsFor(modules),
            onTool: (name, args) async {
              if (cancelled()) return {'error': '用户已取消'};
              final owner = AssistantModuleRegistry.ownerOf(modules, name);
              if (owner?.isProposal(name) == true && proposedAction != null) {
                return {'error': '本轮只能提出一项训练操作，请先确认或取消当前操作'};
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
                result = await AssistantModuleRegistry.invoke(
                  modules,
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
    _generation++;
    ref.read(digitalHumanTtsServiceProvider).stop();
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
