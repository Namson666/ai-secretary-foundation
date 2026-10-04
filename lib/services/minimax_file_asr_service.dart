import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// MiniMax ASR 1.0 accepts an uploaded recording, not a live microphone stream.
class MiniMaxFileAsrService {
  AudioRecorder? _recorder;
  String? _path;
  CancelToken? _request;

  Future<void> start() async {
    await cancel();
    final recorder = AudioRecorder();
    _recorder = recorder;
    try {
      if (!await recorder.hasPermission()) {
        throw StateError('请允许使用麦克风');
      }
      final temp = await getTemporaryDirectory();
      _path =
          '${temp.path}/minimax_asr_${DateTime.now().microsecondsSinceEpoch}.wav';
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _path!,
      );
    } catch (_) {
      await cancel();
      rethrow;
    }
  }

  Future<String> finish() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder == null) return '';
    final path = await recorder.stop();
    await recorder.dispose();
    final file = File(path ?? _path ?? '');
    try {
      if (!await file.exists() || await file.length() == 0) return '';
      const channel = MethodChannel('com.namson.ai_secretary/config');
      final key = await channel.invokeMethod<String>('getApiKey', {
        'key': 'minimax',
      });
      if (key == null || key.isEmpty) {
        throw StateError('MiniMax API key 未配置');
      }
      final request = CancelToken();
      _request = request;
      final response = await Dio().post<Map<String, dynamic>>(
        'https://api.minimaxi.com/v1/speech_to_text',
        data: FormData.fromMap({
          'model': 'asr-1.0',
          'response_format': 'json',
          'file': await MultipartFile.fromFile(
            file.path,
            filename: 'speech.wav',
          ),
        }),
        options: Options(headers: {'Authorization': 'Bearer $key'}),
        cancelToken: request,
      );
      final data = response.data;
      if (data == null) throw const FormatException('识别服务返回空结果');
      final base = data['base_resp'] as Map?;
      if (base != null && base['status_code'] != 0) {
        throw StateError('MiniMax ASR 失败：${base['status_code']}');
      }
      return (data['text'] as String? ?? '').trim();
    } finally {
      _request = null;
      if (await file.exists()) await file.delete();
      _path = null;
    }
  }

  Future<void> cancel() async {
    _request?.cancel();
    _request = null;
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      await recorder.stop();
      await recorder.dispose();
    }
    final path = _path;
    _path = null;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  void dispose() {
    cancel();
  }
}
