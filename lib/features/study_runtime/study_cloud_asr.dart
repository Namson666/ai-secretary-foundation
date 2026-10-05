import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../../services/local_streaming_asr_service.dart';

/// Real 16k mono recording. Silence segments each call utterance; MiniMax's
/// multilingual file recognizer supplies the transcript after the segment ends.
/// No recording is saved to disk or retained after cancellation.
class StudyCloudAsr extends LocalStreamingAsrService {
  StudyCloudAsr({Dio? dio, AudioRecorder Function()? recorderFactory})
    : _recorderFactory = recorderFactory ?? AudioRecorder.new,
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 40),
            ),
          );
  final Dio _dio;
  final AudioRecorder Function() _recorderFactory;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _subscription;
  CancelToken? _request;
  Future<void>? _starting;
  Future<void>? _stopping;
  int _generation = 0;
  BytesBuilder _audio = BytesBuilder(copy: false);
  Uint8List _preroll = Uint8List(0);
  bool _continuous = false, _voiced = false, _uploading = false;
  int _silence = 0, _samples = 0, _candidateSamples = 0;
  PartialTranscript? _partial, _utterance;
  void Function()? _onset;
  void Function(Uint8List)? _pcm;
  void Function()? onFailure;

  @override
  Future<void> prepare() async {}
  @override
  Future<bool> get isCapturing async => await _recorder?.isRecording() ?? false;

  @override
  Future<void> start(PartialTranscript onPartial) => _begin(onPartial);

  @override
  Future<void> startConversation({
    required PartialTranscript onPartial,
    required PartialTranscript onUtterance,
    required void Function() onSpeechStart,
    void Function(Uint8List)? onPcm,
  }) => _begin(
    onPartial,
    utterance: onUtterance,
    onset: onSpeechStart,
    pcm: onPcm,
  );

  Future<void> _begin(
    PartialTranscript partial, {
    PartialTranscript? utterance,
    void Function()? onset,
    void Function(Uint8List)? pcm,
  }) async {
    final cleanup = cancel();
    final generation = _generation;
    await cleanup;
    if (generation != _generation) return;
    _partial = partial;
    _utterance = utterance;
    _onset = onset;
    _pcm = pcm;
    _continuous = utterance != null;
    final recorder = _recorderFactory();
    _recorder = recorder;
    final future = () async {
      if (!await recorder.hasPermission()) throw StateError('请允许使用麦克风');
      if (generation != _generation) return;
      final stream = await recorder.startStream(
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
      if (generation != _generation) return;
      _subscription = stream.listen(
        (chunk) => _accept(chunk, generation),
        onError: (Object _) {
          if (generation == _generation) onFailure?.call();
        },
      );
    }();
    _starting = future;
    try {
      await future;
    } catch (_) {
      if (generation == _generation) await cancel();
      rethrow;
    } finally {
      if (identical(_starting, future)) _starting = null;
    }
  }

  void _accept(Uint8List chunk, int generation) {
    if (generation != _generation || _uploading) return;
    // Runtime freezes its domain context before any transcription request.
    _pcm?.call(chunk);
    if (!_continuous) {
      _audio.add(Uint8List.fromList(chunk));
      return;
    }
    final count = chunk.length ~/ 2;
    if (count == 0) return;
    final data = ByteData.sublistView(chunk);
    double energy = 0;
    for (var i = 0; i < count; i++) {
      final value = data.getInt16(i * 2, Endian.little) / 32768;
      energy += value * value;
    }
    final speaking = math.sqrt(energy / count) >= .018;
    if (!_voiced) {
      _candidateSamples = speaking ? _candidateSamples + count : 0;
      if (_candidateSamples < 960) {
        final buffered = Uint8List.fromList([..._preroll, ...chunk]);
        _preroll = Uint8List.sublistView(
          buffered,
          math.max(0, buffered.length - 6400),
        );
        return;
      }
      _voiced = true;
      _onset?.call();
      _audio.add(_preroll);
    }
    _audio.add(Uint8List.fromList(chunk));
    _samples += count;
    _silence = speaking ? 0 : _silence + count;
    if (_silence >= 12800 || _samples >= 400000) {
      _uploading = true;
      final bytes = _audio.takeBytes();
      _partial?.call('正在识别语音…');
      unawaited(_transcribeUtterance(bytes, generation));
    }
  }

  Future<void> _transcribeUtterance(Uint8List bytes, int generation) async {
    try {
      // Do not close a synchronous PCM controller from inside its onData event.
      await Future<void>.value();
      if (generation != _generation) return;
      await _stopRecorder();
      if (generation != _generation) return;
      final text = await transcribePcm(bytes);
      if (generation != _generation) return;
      if (text.isEmpty) {
        onFailure?.call();
        return;
      }
      _utterance?.call(text);
    } catch (_) {
      if (generation == _generation) onFailure?.call();
    }
  }

  @override
  Future<String> finish() async {
    final generation = _generation;
    await _starting;
    await _stopRecorder();
    if (generation != _generation) return '';
    final bytes = _audio.takeBytes();
    if (bytes.length < 3200) return '';
    final text = await transcribePcm(bytes);
    return generation == _generation ? text : '';
  }

  /// Also used by the native integration probe with fixed synthetic PCM.
  Future<String> transcribePcm(Uint8List pcm) async {
    const channel = MethodChannel('com.namson.ai_secretary/config');
    final generation = _generation;
    final key = await channel.invokeMethod<String>('getApiKey', {
      'key': 'minimax',
    });
    if (generation != _generation) return '';
    if (key == null || key.isEmpty) throw StateError('语音识别服务未配置');
    final request = CancelToken();
    _request = request;
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        'https://api.minimax.cn/v1/speech_to_text',
        options: Options(headers: {'Authorization': 'Bearer $key'}),
        cancelToken: request,
        data: FormData.fromMap({
          'model': 'asr-1.0',
          'response_format': 'json',
          'file': MultipartFile.fromBytes(
            wavFromPcm(pcm),
            filename: 'speech.wav',
            contentType: DioMediaType('audio', 'wav'),
          ),
        }),
      );
      return (response.data?['text'] as String? ?? '').trim();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return '';
      throw StateError('云语音识别暂不可用，请检查网络或切换文字');
    } finally {
      if (identical(_request, request)) _request = null;
    }
  }

  static Uint8List wavFromPcm(Uint8List pcm) {
    final bytes = Uint8List(44 + pcm.length);
    final data = ByteData.sublistView(bytes);
    void ascii(int offset, String value) =>
        bytes.setRange(offset, offset + value.length, value.codeUnits);
    ascii(0, 'RIFF');
    data.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 16000, Endian.little);
    data.setUint32(28, 32000, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, pcm.length, Endian.little);
    bytes.setRange(44, bytes.length, pcm);
    return bytes;
  }

  Future<void> _stopRecorder() =>
      _stopping ??= _releaseRecorder().whenComplete(() {
        _stopping = null;
      });

  Future<void> _releaseRecorder() async {
    final recorder = _recorder;
    _recorder = null;
    final subscription = _subscription;
    _subscription = null;
    try {
      if (recorder != null) await recorder.stop();
    } finally {
      try {
        await subscription?.cancel();
      } finally {
        await recorder?.dispose();
      }
    }
  }

  @override
  Future<void> cancel() async {
    ++_generation;
    _request?.cancel();
    _request = null;
    _partial = null;
    _utterance = null;
    _onset = null;
    _pcm = null;
    _audio = BytesBuilder(copy: false);
    _preroll = Uint8List(0);
    _voiced = false;
    _uploading = false;
    _silence = 0;
    _samples = 0;
    _candidateSamples = 0;
    // A start finishing late must not leave an unowned recording stream.
    await _starting?.catchError((Object _) {});
    await _stopRecorder();
  }

  @override
  void dispose() {
    unawaited(cancel().catchError((Object _) {}));
  }
}
