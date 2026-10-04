import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../core/utils/logger.dart';

typedef AsrTextCallback = void Function(String text);

/// Aliyun's real-time Flash ASR is optional; no request is made until a call
/// explicitly selects this engine.
class AliyunRealtimeAsrService {
  static const model = 'qwen-audio-3.1-asr-flash-streaming';

  WebSocket? _socket;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audio;
  StreamSubscription<dynamic>? _events;
  Completer<void>? _started;
  Completer<void>? _finished;
  String? _taskId;
  String _finalText = '';
  Object? _failure;
  void Function(Object error)? _onError;
  bool _closed = true;

  Future<bool> get isCapturing async {
    final recorder = _recorder;
    if (_closed || recorder == null || _socket?.readyState != WebSocket.open) {
      return false;
    }
    try {
      return await recorder.isRecording();
    } catch (_) {
      return false;
    }
  }

  static String safeError(Object error) {
    final detail = error
        .toString()
        .replaceFirst(RegExp(r'^Bad state: '), '')
        .replaceAll(RegExp(r'sk-[A-Za-z0-9_-]+'), '[REDACTED]')
        .replaceAll(RegExp(r'wss?://\S+'), '[ASR endpoint]')
        .replaceAll(
          RegExp(r'Bearer\s+\S+', caseSensitive: false),
          'Bearer [REDACTED]',
        );
    return detail.length <= 400 ? detail : '${detail.substring(0, 400)}…';
  }

  Future<void> start({
    required AsrTextCallback onPartial,
    required AsrTextCallback onFinal,
    required void Function() onSpeechStart,
    void Function(Object error)? onError,
  }) async {
    await stop();
    const channel = MethodChannel('com.namson.ai_secretary/config');
    final key = await channel.invokeMethod<String>('getApiKey', {
      'key': 'bailian_api_key',
    });
    final workspace = await channel.invokeMethod<String>('getApiKey', {
      'key': 'bailian_workspace_id',
    });
    if (key == null || key.isEmpty || workspace == null || workspace.isEmpty) {
      throw StateError('百炼实时识别未配置');
    }
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(workspace)) {
      throw StateError('百炼业务空间 ID 格式错误');
    }

    _closed = false;
    _finalText = '';
    _failure = null;
    _onError = onError;
    _taskId = _uuid();
    _started = Completer<void>();
    _finished = Completer<void>();
    try {
      final socket = await WebSocket.connect(
        'wss://$workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference',
        headers: {'Authorization': 'Bearer $key'},
      ).timeout(const Duration(seconds: 10));
      if (_closed) {
        await socket.close();
        return;
      }
      _socket = socket;
      _events = socket.listen(
        (dynamic data) {
          if (_closed || data is! String) return;
          try {
            final event = jsonDecode(data) as Map<String, dynamic>;
            final name = (event['header'] as Map?)?['event'];
            if (name == 'task-started') {
              if (!(_started?.isCompleted ?? true)) _started!.complete();
              return;
            }
            if (name == 'task-failed') {
              final code = (event['header'] as Map?)?['error_code'];
              final message = (event['header'] as Map?)?['error_message'];
              _fail(StateError('百炼实时识别失败：$code ${message ?? ''}'));
              return;
            }
            if (name == 'task-finished') {
              if (!(_finished?.isCompleted ?? true)) _finished!.complete();
              return;
            }
            if (name != 'result-generated') return;
            final sentence =
                ((event['payload'] as Map?)?['output'] as Map?)?['sentence']
                    as Map?;
            if (sentence == null || sentence['heartbeat'] == true) return;
            if (sentence['sentence_begin'] == true) onSpeechStart();
            final text = (sentence['text'] as String? ?? '').trim();
            if (text.isEmpty) return;
            if (sentence['sentence_end'] == true) {
              _finalText += text;
              onFinal(text);
            } else {
              onPartial(text);
            }
          } catch (error) {
            Logger.w('AliyunRealtimeAsr', 'Invalid event: $error');
          }
        },
        onError: (Object error) =>
            _fail(StateError('百炼实时识别连接中断：${safeError(error)}')),
        onDone: () {
          if (!(_finished?.isCompleted ?? false)) {
            _fail(StateError('百炼实时识别连接已关闭'));
          }
        },
      );
      socket.add(
        jsonEncode({
          'header': {
            'action': 'run-task',
            'task_id': _taskId,
            'streaming': 'duplex',
          },
          'payload': {
            'task_group': 'audio',
            'task': 'asr',
            'function': 'recognition',
            'model': model,
            'parameters': {
              'format': 'pcm',
              'sample_rate': 16000,
              'vad_model': 'near_meeting_16k',
              'semantic_punctuation_enabled': false,
              'max_sentence_silence': 800,
              'heartbeat': true,
              'language_hints': ['zh', 'en'],
            },
            'input': {},
          },
        }),
      );
      await _started!.future.timeout(const Duration(seconds: 10));
      if (_failure != null) throw _failure!;
      if (_closed) return;
      final recorder = AudioRecorder();
      _recorder = recorder;
      if (!await recorder.hasPermission()) {
        throw StateError('请允许使用麦克风');
      }
      final stream = await recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          streamBufferSize: 3200,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceCommunication,
            audioManagerMode: AudioManagerMode.modeInCommunication,
          ),
        ),
      );
      _audio = stream.listen((chunk) {
        if (!_closed && _socket?.readyState == WebSocket.open) {
          _socket?.add(chunk);
        }
      });
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _failure = error;
    if (!(_started?.isCompleted ?? true)) _started!.complete();
    if (!(_finished?.isCompleted ?? true)) _finished!.complete();
    Logger.w('AliyunRealtimeAsr', safeError(error));
    _onError?.call(error);
  }

  Future<String> finish() async {
    try {
      await _audio?.cancel();
      _audio = null;
      final recorder = _recorder;
      _recorder = null;
      if (recorder != null) {
        await recorder.stop();
        await recorder.dispose();
      }
      final socket = _socket;
      if (!_closed && socket?.readyState == WebSocket.open && _taskId != null) {
        socket!.add(
          jsonEncode({
            'header': {
              'action': 'finish-task',
              'task_id': _taskId,
              'streaming': 'duplex',
            },
            'payload': {'input': {}},
          }),
        );
        await _finished!.future.timeout(const Duration(seconds: 10));
      }
      if (_failure != null) throw _failure!;
      return _finalText.trim();
    } finally {
      await stop();
    }
  }

  Future<void> stop() async {
    _closed = true;
    _failure = null;
    if (!(_started?.isCompleted ?? true)) _started!.complete();
    if (!(_finished?.isCompleted ?? true)) _finished!.complete();
    await _audio?.cancel();
    _audio = null;
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        await recorder.stop();
      } finally {
        await recorder.dispose();
      }
    }
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      if (socket.readyState == WebSocket.open &&
          _taskId != null &&
          !(_finished?.isCompleted ?? true)) {
        socket.add(
          jsonEncode({
            'header': {
              'action': 'finish-task',
              'task_id': _taskId,
              'streaming': 'duplex',
            },
            'payload': {'input': {}},
          }),
        );
      }
      await socket.close();
    }
    await _events?.cancel();
    _events = null;
    _taskId = null;
    _started = null;
    _finished = null;
    _onError = null;
  }

  void dispose() {
    unawaited(stop());
  }

  static String _uuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  static final Random _random = Random.secure();
}
