import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';

import '../../core/assistant/assistant_context.dart';
import '../../services/ai_latency_service.dart';
import '../../services/call_foreground_service.dart';
import '../../services/local_streaming_asr_service.dart';
import '../../services/tts_service.dart';
import 'study_cloud_client.dart';
import 'study_cloud_asr.dart';
import 'study_voice_start_detector.dart';

enum StudyConversationPhase {
  idle,
  recording,
  transcribing,
  thinking,
  speaking,
  listening,
}

@immutable
class StudyInputContext {
  final String? focusId;
  final AssistantContextSnapshot? snapshot;
  final String systemPrompt;
  final bool Function()? _lease;
  final String? requestId;
  final String? commandId;
  final String? userText;
  final String? toolCallId;
  String? get finalText => userText;
  String? get inputId => requestId;
  bool get isCurrent => _lease?.call() ?? true;
  const StudyInputContext({
    this.focusId,
    this.snapshot,
    this.systemPrompt =
        '你是一位亲切的对话伙伴，按用户当前意图回答。用户想练英语时给简短清楚的反馈。不可声称已保存、安排或撤销，除非本轮工具返回成功回执。',
  }) : _lease = null,
       requestId = null,
       commandId = null,
       userText = null,
       toolCallId = null;

  StudyInputContext._leased(
    StudyInputContext source,
    this._lease,
    this.requestId,
    this.userText,
  ) : focusId = source.focusId,
      snapshot = source.snapshot,
      systemPrompt = source.systemPrompt,
      commandId = null,
      toolCallId = null;

  StudyInputContext._tool(StudyInputContext source, String toolId)
    : focusId = source.focusId,
      snapshot = source.snapshot,
      systemPrompt = source.systemPrompt,
      _lease = source._lease,
      requestId = source.requestId,
      userText = source.userText,
      toolCallId = toolId,
      commandId = '${source.requestId}/$toolId';

  StudyInputContext forToolCall(String toolId) {
    if (requestId == null ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(toolId)) {
      throw const FormatException('操作标识无效');
    }
    return StudyInputContext._tool(this, toolId);
  }
}

@immutable
class StudyChatMessage {
  final String text;
  final bool isUser;
  final bool isVoice;
  const StudyChatMessage(
    this.text, {
    required this.isUser,
    this.isVoice = false,
  });
}

typedef StudyToolHandler =
    Future<Map<String, dynamic>> Function(
      String name,
      Map<String, dynamic> args,
      StudyInputContext captured,
    );

/// Owns microphone, recognition, network requests, playback and call lifetime.
/// The host captures its immutable domain context; this runtime never resolves a
/// current screen focus after recognition or writes a domain database itself.
class StudyConversationRuntime extends ChangeNotifier
    with WidgetsBindingObserver {
  final StudyInputContext Function()? captureContext;
  final StudyToolHandler? onTool;
  final List<Map<String, dynamic>> tools;
  final LocalStreamingAsrService _asr;
  final StudyVoiceStartDetector _voiceStart = StudyVoiceStartDetector();
  final StudyCloudClient _cloud;
  final TtsService _tts;
  final Future<void> Function() _stopForeground;
  final List<StudyChatMessage> _messages = [];
  StudyConversationPhase phase = StudyConversationPhase.idle;
  String partial = '';
  String? error;
  bool callActive = false;
  bool muted = false;
  bool speakerEnabled = true;
  Duration elapsed = Duration.zero;
  bool _closed = false;
  int _epoch = 0;
  int _audioEpoch = 0;
  bool _starting = false;
  bool _finishing = false;
  bool _endingCall = false;
  bool _muting = false;
  bool _micStopFailed = false;
  Future<void>? _micStopping;
  Future<void>? _muteStopping;
  StudyInputContext? _captured;
  Timer? _timer;
  Timer? _holdLimit;
  DateTime? _callStarted;
  void Function()? _removeStopHandler;
  Future<void>? _closing;

  StudyConversationRuntime({
    this.captureContext,
    this.onTool,
    List<Map<String, dynamic>> tools = const [],
    LocalStreamingAsrService? asr,
    StudyCloudClient? cloud,
    TtsService? tts,
    Future<void> Function()? stopForeground,
  }) : _stopForeground = stopForeground ?? CallForegroundService.stop,
       tools = List.unmodifiable(tools),
       _asr = asr ?? StudyCloudAsr(),
       _cloud = cloud ?? StudyCloudClient(),
       _tts =
           tts ??
           TtsService(
             dio: Dio(
               BaseOptions(
                 baseUrl: 'https://api.minimax.cn/v1',
                 connectTimeout: const Duration(seconds: 10),
                 receiveTimeout: const Duration(seconds: 30),
               ),
             ),
             latencyService: _StudyLatency(),
             model: () => 'speech-2.8-turbo',
           ) {
    WidgetsBinding.instance.addObserver(this);
    if (_asr case final StudyCloudAsr recognition) {
      recognition.onFailure = () {
        if (!_closed && callActive && !muted) {
          error = '云语音识别暂不可用，可结束通话后使用文字';
          unawaited(endCall());
          _notify();
        }
      };
    }
    _removeStopHandler = CallForegroundService.onStopRequested(endCall);
  }

  List<StudyChatMessage> get messages => List.unmodifiable(_messages);
  List<Map<String, dynamic>> get toolReceipts => _cloud.receipts;
  String? get actualModel => _cloud.actualModel;
  Map<String, dynamic>? get lastUsage => _cloud.lastUsage;
  bool get busy =>
      _endingCall ||
      _muting ||
      _starting ||
      _finishing ||
      phase == StudyConversationPhase.transcribing ||
      phase == StudyConversationPhase.thinking ||
      phase == StudyConversationPhase.speaking;
  bool _current(int epoch) => !_closed && epoch == _epoch;
  StudyInputContext _capture() =>
      captureContext?.call() ?? const StudyInputContext();
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> sendText(String text) async {
    if (_closed || busy || phase == StudyConversationPhase.recording) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final captured = _capture();
    final epoch = ++_epoch;
    if (callActive) await _stopMic();
    if (!_current(epoch)) return;
    await _respond(trimmed, captured, epoch, isVoice: false);
    if (_current(epoch) && callActive && !muted) await _listen(epoch);
  }

  Future<void> startHold() async {
    if (_closed ||
        busy ||
        callActive ||
        phase == StudyConversationPhase.recording) {
      return;
    }
    final epoch = ++_epoch;
    _captured = _capture();
    error = null;
    partial = '';
    _starting = true;
    phase = StudyConversationPhase.recording;
    _notify();
    _holdLimit = Timer(const Duration(seconds: 30), () {
      unawaited(cancelHold());
    });
    try {
      await _asr.start((text) {
        if (_current(epoch)) {
          partial = text;
          _notify();
        }
      });
    } catch (_) {
      if (_current(epoch)) {
        error = '录音启动失败，请检查麦克风权限；仍可切换文字';
        phase = StudyConversationPhase.idle;
      }
    } finally {
      _starting = false;
      _notify();
    }
  }

  Future<void> finishHold() async {
    if (_closed || phase != StudyConversationPhase.recording || _finishing) {
      return;
    }
    final epoch = _epoch;
    final captured = _captured ?? const StudyInputContext();
    _holdLimit?.cancel();
    _holdLimit = null;
    _finishing = true;
    phase = StudyConversationPhase.transcribing;
    _notify();
    try {
      final text = await _asr.finish();
      if (!_current(epoch)) return;
      if (text.trim().isEmpty) {
        error = '没有识别到语音，请重试或切换文字';
        phase = StudyConversationPhase.idle;
      } else {
        await _respond(text.trim(), captured, epoch, isVoice: true);
      }
    } catch (_) {
      if (_current(epoch)) {
        error = '语音识别失败，请重试或切换文字';
        phase = StudyConversationPhase.idle;
      }
    } finally {
      _finishing = false;
      _captured = null;
      _notify();
    }
  }

  Future<void> cancelHold() async {
    if (_closed || callActive) return;
    ++_epoch;
    _holdLimit?.cancel();
    _holdLimit = null;
    _captured = null;
    partial = '';
    phase = StudyConversationPhase.idle;
    _cancelNetwork();
    await _cleanupStep(_tts.stop);
    await _stopMic();
    _notify();
  }

  Future<void> startCall() async {
    if (_closed || callActive || busy) return;
    await cancelHold();
    if (_closed) return;
    final epoch = ++_epoch;
    error = null;
    muted = false;
    callActive = true;
    elapsed = Duration.zero;
    _callStarted = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_closed && callActive && _callStarted != null) {
        elapsed = DateTime.now().difference(_callStarted!);
        _notify();
      }
    });
    try {
      await _listen(epoch);
      if (_current(epoch) && callActive && error == null) {
        await CallForegroundService.start();
      }
    } catch (_) {
      if (_current(epoch)) {
        error = '语音通话启动失败，请检查麦克风权限';
        await endCall();
      }
    }
    _notify();
  }

  void _cleanupFailed() {
    error = '音频关闭未完全成功，请退出对话页面后重试；文字学习仍可使用';
    _notify();
  }

  Future<bool> _cleanupStep(FutureOr<void> Function() operation) async {
    try {
      await operation();
      return true;
    } catch (_) {
      _cleanupFailed();
      return false;
    }
  }

  void _cancelNetwork() {
    try {
      _cloud.cancel();
    } catch (_) {
      _cleanupFailed();
    }
  }

  Future<void> _stopMic() {
    final stopping = () async {
      _micStopFailed = !await _cleanupStep(_asr.cancel);
    }();
    _micStopping = stopping;
    return stopping;
  }

  Future<void> _listen(int epoch) async {
    await _micStopping;
    if (!_current(epoch) || !callActive || muted) return;
    if (_micStopFailed) {
      await endCall();
      return;
    }
    phase = StudyConversationPhase.listening;
    partial = '';
    _captured = null;
    _notify();
    _voiceStart.reset();
    try {
      await _asr.startConversation(
        onPartial: (text) {
          if (_current(epoch)) {
            partial = text;
            _notify();
          }
        },
        // Domain ownership is frozen on the audio onset, never first text.
        onSpeechStart: () {},
        onPcm: (pcm) {
          if (_current(epoch) && !muted && _voiceStart.add(pcm)) {
            _captured = _capture();
          }
        },
        onUtterance: (text) {
          if (!_current(epoch) || muted || busy) return;
          final captured = _captured ?? const StudyInputContext();
          phase = StudyConversationPhase.transcribing;
          _notify();
          unawaited(_callUtterance(text, captured, epoch));
        },
      );
    } catch (_) {
      if (_current(epoch)) {
        error = '麦克风或云识别暂不可用，可结束通话后使用文字';
        phase = StudyConversationPhase.idle;
        _notify();
        await endCall();
      }
    }
  }

  Future<void> _callUtterance(
    String text,
    StudyInputContext captured,
    int epoch,
  ) async {
    await _stopMic();
    if (!_current(epoch) || !callActive || muted) return;
    await _respond(text, captured, epoch, isVoice: true);
    if (_current(epoch) && callActive && !muted) await _listen(epoch);
  }

  Future<void> _respond(
    String text,
    StudyInputContext captured,
    int epoch, {
    required bool isVoice,
  }) async {
    error = null;
    partial = '';
    phase = StudyConversationPhase.thinking;
    _messages.add(StudyChatMessage(text, isUser: true, isVoice: isVoice));
    _notify();
    try {
      final reply = await _cloud.reply(
        messages: messages,
        context: StudyInputContext._leased(
          captured,
          () => _current(epoch),
          'turn_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}',
          text,
        ),
        tools: tools,
        onTool: onTool,
        isCurrent: () => _current(epoch),
      );
      if (!_current(epoch) || reply.isEmpty) return;
      _messages.add(StudyChatMessage(reply, isUser: false));
      _notify();
      if (speakerEnabled) {
        phase = StudyConversationPhase.speaking;
        _notify();
        try {
          await _tts.speak(reply);
        } catch (_) {
          if (_current(epoch)) error = '语音播放暂不可用，回复文字已保留';
        }
      }
    } catch (e) {
      if (_current(epoch)) {
        error = e is StateError
            ? e.message.toString()
            : '对话暂不可用，请稍后重试；基础学习仍可使用';
      }
    } finally {
      if (_current(epoch)) {
        phase = callActive
            ? StudyConversationPhase.listening
            : StudyConversationPhase.idle;
        _notify();
      }
    }
  }

  Future<void> setMuted(bool value) async {
    if (_closed || !callActive || value == muted) return;
    muted = value;
    _notify();
    if (value) {
      ++_epoch;
      _cancelNetwork();
      _captured = null;
      partial = '';
      phase = StudyConversationPhase.idle;
      _muting = true;
      final stopping = _stopMuted();
      _muteStopping = stopping;
      try {
        await stopping;
      } finally {
        if (identical(_muteStopping, stopping)) _muting = false;
      }
      _notify();
    } else {
      await _muteStopping;
      if (_closed || !callActive || muted) return;
      await _listen(_epoch);
    }
  }

  Future<void> _stopMuted() async {
    await _stopMic();
    await _cleanupStep(_tts.stop);
  }

  Future<void> setSpeaker(bool value) async {
    if (_closed) return;
    speakerEnabled = value;
    _notify();
    if (!value) {
      ++_audioEpoch;
      await _cleanupStep(_tts.stop);
    }
  }

  /// Learning audio shares the conversation output owner. Completion means the
  /// actual playback finished; an interrupted or failed playback earns no evidence.
  Future<bool> playReference(String text) async {
    if (text.trim().isEmpty) return false;
    if (_closed ||
        callActive ||
        busy ||
        phase == StudyConversationPhase.recording ||
        !speakerEnabled) {
      error = callActive ? '请先结束通话再播放示范音频' : '音频暂不可播放，请检查音频开关';
      _notify();
      return false;
    }
    final epoch = ++_epoch;
    final audioEpoch = _audioEpoch;
    error = null;
    phase = StudyConversationPhase.speaking;
    _notify();
    try {
      await _tts.speak(text);
      return _current(epoch) && audioEpoch == _audioEpoch && speakerEnabled;
    } catch (_) {
      if (_current(epoch)) error = '示范音频播放失败，请稍后重试';
      return false;
    } finally {
      if (_current(epoch)) {
        phase = StudyConversationPhase.idle;
        _notify();
      }
    }
  }

  /// Only a currently executing tool may request this playback. Manual study
  /// playback keeps its stricter idle-only contract; both use this same owner.
  Future<bool> playToolReference(
    String text, {
    required bool Function() isCurrent,
  }) async {
    if (text.trim().isEmpty ||
        _closed ||
        !speakerEnabled ||
        phase != StudyConversationPhase.thinking ||
        !isCurrent()) {
      return false;
    }
    final epoch = _epoch;
    final audioEpoch = _audioEpoch;
    if (callActive) await _stopMic();
    if (_micStopFailed || !_current(epoch) || !isCurrent() || !speakerEnabled) {
      return false;
    }
    final previous = phase;
    phase = StudyConversationPhase.speaking;
    _notify();
    try {
      await _tts.speak(text);
      return _current(epoch) &&
          isCurrent() &&
          speakerEnabled &&
          audioEpoch == _audioEpoch;
    } catch (_) {
      if (_current(epoch)) {
        error = '示范音频播放失败，可继续文字学习';
      }
      return false;
    } finally {
      if (_current(epoch)) {
        phase = previous;
        _notify();
      }
    }
  }

  Future<void> endCall() async {
    if (_closed || _endingCall) return;
    _endingCall = true;
    ++_epoch;
    callActive = false;
    muted = false;
    _timer?.cancel();
    _timer = null;
    _callStarted = null;
    _holdLimit?.cancel();
    _holdLimit = null;
    _captured = null;
    partial = '';
    phase = StudyConversationPhase.idle;
    _cancelNetwork();
    _notify();
    try {
      await _stopMic();
      await _cleanupStep(_tts.stop);
      await _cleanupStep(_stopForeground);
    } finally {
      _endingCall = false;
      _notify();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // System overlays (including the first immersive-mode explanation) can
    // temporarily remove window focus without putting the app in background.
    if (state == AppLifecycleState.inactive) {
      if (phase == StudyConversationPhase.recording) unawaited(cancelHold());
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      if (callActive) {
        unawaited(endCall());
      } else {
        unawaited(cancelHold());
      }
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    ++_epoch;
    _closed = true;
    callActive = false;
    WidgetsBinding.instance.removeObserver(this);
    _removeStopHandler?.call();
    _removeStopHandler = null;
    _timer?.cancel();
    _holdLimit?.cancel();
    _cancelNetwork();
    await _stopMic();
    await _cleanupStep(_asr.dispose);
    await _cleanupStep(_tts.stop);
    // TtsService.dispose only launches another unawaited stop; the awaited
    // stop above already releases its complete playback owner.
    await _cleanupStep(_cloud.dispose);
    await _cleanupStep(_stopForeground);
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

/// Study does not open the legacy health database merely to play speech.
class _StudyLatency extends AiLatencyService {
  @override
  Future<void> recordEvent({
    String? sessionId,
    required String provider,
    required Duration latency,
    bool success = true,
    String? errorMessage,
    int? promptTokens,
    int? completionTokens,
  }) async {}
}
