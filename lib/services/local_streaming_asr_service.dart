import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

typedef PartialTranscript = void Function(String text);

/// On-device streaming ASR. The recognizer stays in an isolate so decoding
/// never blocks avatar animation or microphone gestures on the UI isolate.
class LocalStreamingAsrService {
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSubscription;
  ReceivePort? _messages;
  Isolate? _worker;
  SendPort? _commands;
  Future<void>? _initializing;
  Future<void>? _starting;
  Completer<String>? _finalText;
  PartialTranscript? _onPartial;
  PartialTranscript? _onUtterance;
  void Function()? _onSpeechStart;
  void Function(Uint8List)? _onPcm;
  bool _continuous = false;
  Object? _workerError;
  bool _active = false;
  bool _cancelled = false;
  bool _ending = false;
  bool _recordingStarted = false;

  Future<bool> get isCapturing async {
    final recorder = _recorder;
    if (!_active || recorder == null) return false;
    try {
      return await recorder.isRecording();
    } catch (_) {
      return false;
    }
  }

  Future<void> prepare() => _initializing ??= _initialize().catchError((
    Object error,
    StackTrace stack,
  ) {
    _initializing = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _initialize() async {
    final directory = Directory(
      '${(await getApplicationSupportDirectory()).path}/asr_zipformer_2025_04_01',
    );
    await directory.create(recursive: true);
    const modelFiles = {'model.int8.onnx': 26342340, 'tokens.txt': 13366};
    for (final entry in modelFiles.entries) {
      final name = entry.key;
      final target = File('${directory.path}/$name');
      if (await target.exists() && await target.length() == entry.value) {
        continue;
      }
      final asset = await rootBundle.load('assets/asr/zipformer/$name');
      if (asset.lengthInBytes != entry.value) {
        throw StateError('语音模型文件不完整：$name');
      }
      final pending = File('${target.path}.pending');
      await pending.writeAsBytes(asset.buffer.asUint8List(), flush: true);
      await pending.rename(target.path);
    }

    final ready = Completer<void>();
    final receive = ReceivePort();
    _messages = receive;
    receive.listen((dynamic message) {
      final event = message as List<dynamic>;
      switch (event[0]) {
        case 'ready':
          _commands = event[1] as SendPort;
          if (!ready.isCompleted) ready.complete();
        case 'partial':
          if (_active && !_cancelled && !_ending) {
            _onPartial?.call(event[1] as String);
          }
        case 'speech_start':
          if (_active && !_cancelled && !_ending) _onSpeechStart?.call();
        case 'utterance':
          if (_active && !_cancelled && !_ending) {
            _onUtterance?.call(event[1] as String);
          }
        case 'final':
          if (_finalText case final completer?) {
            if (!completer.isCompleted) completer.complete(event[1] as String);
          }
        case 'error':
          final error = StateError('本地语音识别失败：${event[1]}');
          _workerError = error;
          if (!ready.isCompleted) ready.completeError(error);
          if (_finalText case final completer?) {
            if (!completer.isCompleted) completer.completeError(error);
          }
      }
    });
    try {
      _worker = await Isolate.spawn(_asrWorker, [
        receive.sendPort,
        '${directory.path}/model.int8.onnx',
        '${directory.path}/tokens.txt',
      ]);
      await ready.future.timeout(const Duration(seconds: 20));
    } catch (_) {
      _worker?.kill(priority: Isolate.immediate);
      receive.close();
      _messages = null;
      _commands = null;
      rethrow;
    }
  }

  Future<void> start(PartialTranscript onPartial) {
    if (_active) throw StateError('语音识别已经开始');
    _workerError = null;
    _active = true;
    _cancelled = false;
    _ending = false;
    _onPartial = onPartial;
    return _starting = _start();
  }

  Future<void> startConversation({
    required PartialTranscript onPartial,
    required PartialTranscript onUtterance,
    required void Function() onSpeechStart,
    void Function(Uint8List)? onPcm,
  }) {
    _continuous = true;
    _onUtterance = onUtterance;
    _onSpeechStart = onSpeechStart;
    _onPcm = onPcm;
    return start(onPartial);
  }

  Future<void> _start() async {
    try {
      await prepare();
      if (_workerError != null) throw _workerError!;
      if (_cancelled) return;
      final recorder = AudioRecorder();
      _recorder = recorder;
      if (!await recorder.hasPermission()) {
        throw StateError('请允许使用麦克风');
      }
      if (_cancelled) return;
      _commands!.send(['start', _continuous]);
      final audio = await recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          streamBufferSize: 3200,
          androidConfig: _continuous
              ? const AndroidRecordConfig(
                  audioSource: AndroidAudioSource.voiceCommunication,
                  audioManagerMode: AudioManagerMode.modeInCommunication,
                )
              : const AndroidRecordConfig(),
        ),
      );
      _recordingStarted = true;
      _audioSubscription = audio.listen(
        (chunk) {
          if (_active && !_cancelled && !_ending) _onPcm?.call(chunk);
          _commands?.send(['audio', chunk]);
        },
        onError: (Object error) {
          final completer = _finalText;
          if (completer != null && !completer.isCompleted) {
            completer.completeError(error);
          }
        },
      );
      if (_cancelled) await _stopCapture();
    } catch (_) {
      _commands?.send(['cancel']);
      await _stopCapture();
      _active = false;
      rethrow;
    }
  }

  Future<String> finish() async {
    if (!_active) return '';
    _ending = true;
    try {
      await _starting;
      if (_cancelled) return '';
      _finalText = Completer<String>();
      await _stopCapture();
      if (_cancelled) return '';
      if (_workerError != null) throw _workerError!;
      _commands!.send(['finish']);
      return await _finalText!.future.timeout(const Duration(seconds: 15));
    } finally {
      _active = false;
      _onPartial = null;
      _onUtterance = null;
      _onSpeechStart = null;
      _onPcm = null;
      _continuous = false;
      _finalText = null;
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    _onPartial = null;
    _onUtterance = null;
    _onSpeechStart = null;
    _onPcm = null;
    _continuous = false;
    try {
      await _starting;
    } catch (_) {
      // A start failure already belongs to its caller.
    }
    await _stopCapture();
    _commands?.send(['cancel']);
    final completer = _finalText;
    if (completer != null && !completer.isCompleted) completer.complete('');
    _active = false;
  }

  Future<void> _stopCapture() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        if (_recordingStarted) await recorder.stop();
      } finally {
        _recordingStarted = false;
        await recorder.dispose();
      }
    }
    await _audioSubscription?.cancel();
    _audioSubscription = null;
  }

  void dispose() {
    _cancelled = true;
    _commands?.send(['close']);
    _worker?.kill(priority: Isolate.immediate);
    _messages?.close();
    _recorder?.dispose();
  }
}

void _asrWorker(List<dynamic> arguments) async {
  final output = arguments[0] as SendPort;
  final input = ReceivePort();
  sherpa.OnlineRecognizer? recognizer;
  sherpa.OnlineStream? stream;
  var completed = '';
  var continuous = false;
  var speechStarted = false;
  try {
    sherpa.initBindings();
    recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          zipformer2Ctc: sherpa.OnlineZipformer2CtcModelConfig(
            model: arguments[1] as String,
          ),
          tokens: arguments[2] as String,
          modelingUnit: 'cjkchar',
          numThreads: 1,
          debug: false,
        ),
      ),
    );
    output.send(['ready', input.sendPort]);
    await for (final dynamic value in input) {
      final command = value as List<dynamic>;
      try {
        switch (command[0]) {
          case 'start':
            stream?.free();
            stream = recognizer.createStream();
            completed = '';
            continuous = command.length > 1 && command[1] == true;
            speechStarted = false;
          case 'audio':
            if (stream == null) break;
            final bytes = command[1] as Uint8List;
            final pcm = ByteData.sublistView(bytes);
            final samples = Float32List(bytes.length ~/ 2);
            for (var i = 0; i < samples.length; i++) {
              samples[i] = pcm.getInt16(i * 2, Endian.little) / 32768.0;
            }
            stream.acceptWaveform(samples: samples, sampleRate: 16000);
            while (recognizer.isReady(stream)) {
              recognizer.decode(stream);
            }
            final current = recognizer.getResult(stream).text;
            if (current.isNotEmpty && !speechStarted) {
              speechStarted = true;
              output.send(['speech_start']);
            }
            output.send(['partial', '$completed$current']);
            if (recognizer.isEndpoint(stream)) {
              if (continuous) {
                if (current.trim().isNotEmpty) {
                  output.send(['utterance', current.trim()]);
                }
                speechStarted = false;
              } else {
                completed += current;
              }
              recognizer.reset(stream);
            }
          case 'finish':
            if (stream == null) {
              output.send(['final', '']);
              break;
            }
            stream.inputFinished();
            while (recognizer.isReady(stream)) {
              recognizer.decode(stream);
            }
            final text = '$completed${recognizer.getResult(stream).text}'
                .trim();
            output.send(['final', text]);
            stream.free();
            stream = null;
          case 'cancel':
            stream?.free();
            stream = null;
            completed = '';
          case 'close':
            return;
        }
      } catch (error) {
        output.send(['error', error.toString()]);
        stream?.free();
        stream = null;
      }
    }
  } catch (error) {
    output.send(['error', error.toString()]);
  } finally {
    stream?.free();
    recognizer?.free();
    input.close();
  }
}
