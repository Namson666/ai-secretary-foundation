import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../core/utils/constants.dart';
import '../core/assistant/speech_direction.dart';
import '../core/utils/logger.dart';
import 'ai_latency_service.dart';
import 'avatar_audio_bridge.dart';
import 'minimax_voice_catalog.dart';

class TtsService {
  late final Dio _dio;
  final AiLatencyService _latencyService;
  final String Function()? voiceId;
  final String Function()? model;
  final double Function()? speed;
  final bool preferAvatar;
  String? _cachedApiKey;
  AudioPlayer? _player;
  String? _lastFilePath;
  int _generation = 0;
  CancelToken? _cancelToken;

  TtsService({
    AiLatencyService? latencyService,
    Dio? dio,
    this.voiceId,
    this.model,
    this.speed,
    this.preferAvatar = true,
  }) : _latencyService = latencyService ?? AiLatencyService() {
    _dio =
        dio ??
        Dio(
          BaseOptions(
            baseUrl: AppConstants.ttsBaseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 30),
            headers: {'Content-Type': 'application/json'},
          ),
        );
  }

  /// Get MiniMax key via MethodChannel.
  Future<String?> _getApiKey() async {
    if (_cachedApiKey != null) return _cachedApiKey;

    try {
      const channel = MethodChannel('com.namson.ai_secretary/config');
      final key = await channel.invokeMethod<String>('getApiKey', {
        'key': 'minimax',
      });
      if (key != null && key.isNotEmpty) {
        _cachedApiKey = key;
      }
      return key;
    } on MissingPluginException {
      Logger.w(
        'TtsService',
        'MethodChannel not available (likely non-mobile platform)',
      );
      return null;
    } catch (e) {
      Logger.e('TtsService', 'Failed to get API key: $e');
      return null;
    }
  }

  /// Synthesise [text] to speech and play it.
  ///
  /// Uses MiniMax T2A v2 HTTP API.
  /// Stops any current playback before starting a new one.
  Future<void> speak(String text, {String? emotion}) async {
    if (text.trim().isEmpty) return;

    final stopping = stop();
    final generation = _generation;
    bool cancelled() => generation != _generation;
    await stopping;
    if (cancelled()) return;
    final token = CancelToken();
    _cancelToken = token;
    final trace = _latencyService.startTrace();
    try {
      final apiKey = await _getApiKey();
      if (cancelled()) return;
      if (apiKey == null || apiKey.isEmpty) {
        throw Exception('MiniMax API key not configured');
      }

      final selectedModel = model?.call();
      final body = <String, dynamic>{
        'model': AppConstants.ttsChoices.contains(selectedModel)
            ? selectedModel
            : AppConstants.ttsModel,
        'text': text,
        'stream': false,
        'output_format': 'hex',
        'voice_setting': {
          'voice_id': MiniMaxVoiceCatalog.validatedId(voiceId?.call()),
          'speed': (speed?.call() ?? 1.0).clamp(0.5, 2.0),
          'vol': 1,
          'pitch': 0,
          if (SpeechDirection.emotions.contains(emotion)) 'emotion': emotion,
        },
        'audio_setting': {'sample_rate': 16000, 'format': 'pcm', 'channel': 1},
      };

      final response = await _dio.post<Map<String, dynamic>>(
        '/t2a_v2',
        data: body,
        cancelToken: token,
        options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
      );
      if (cancelled()) return;

      final data = response.data;
      _validateMiniMaxResponse(data);
      final audioHex = data?['data'] is Map<String, dynamic>
          ? (data!['data'] as Map<String, dynamic>)['audio'] as String?
          : null;
      final audioBytes = audioHex == null ? null : _decodeHexAudio(audioHex);
      if (audioBytes == null || audioBytes.isEmpty || audioBytes.length.isOdd) {
        throw Exception('Empty response from TTS API');
      }

      await _latencyService.recordEvent(
        provider: 'tts.minimax_t2a_v2_ready',
        latency: trace.elapsed,
      );
      if (cancelled()) return;
      final playedByAvatar =
          preferAvatar &&
          await AvatarAudioBridge.play(Uint8List.fromList(audioBytes));
      if (playedByAvatar || cancelled()) return;

      // History/non-avatar screens use the same PCM in a WAV container.
      final tempDir = await getTemporaryDirectory();
      if (cancelled()) return;
      final filePath =
          '${tempDir.path}/tts_${DateTime.now().microsecondsSinceEpoch}.wav';
      final file = File(filePath);
      await file.writeAsBytes(pcmToWav(Uint8List.fromList(audioBytes)));
      if (cancelled()) {
        await file.delete();
        return;
      }
      _lastFilePath = filePath;

      // Create player and play
      final player = AudioPlayer();
      _player = player;
      await player.setAudioSource(AudioSource.file(filePath));
      if (cancelled()) return;
      await player.play();
    } on DioException catch (e) {
      if (cancelled() || CancelToken.isCancel(e)) return;
      Logger.e('TtsService', 'Dio error: ${e.message}');
      await _latencyService.recordEvent(
        provider: 'tts.minimax_t2a_v2_ready',
        latency: trace.elapsed,
        success: false,
        errorMessage: e.message,
      );
      throw Exception('TTS request failed: ${e.message}');
    } catch (e) {
      if (cancelled()) return;
      await _latencyService.recordEvent(
        provider: 'tts.minimax_t2a_v2_ready',
        latency: trace.elapsed,
        success: false,
        errorMessage: e.toString(),
      );
      rethrow;
    } finally {
      if (!cancelled()) {
        _cancelToken = null;
        final player = _player;
        _player = null;
        await player?.dispose();
        _cleanupFile();
      }
    }
  }

  static Uint8List pcmToWav(Uint8List pcm) {
    if (pcm.isEmpty || pcm.length.isOdd) {
      throw const FormatException('Invalid 16-bit PCM audio');
    }
    final bytes = Uint8List(44 + pcm.length);
    final header = ByteData.sublistView(bytes);
    bytes.setRange(0, 4, ascii.encode('RIFF'));
    header.setUint32(4, 36 + pcm.length, Endian.little);
    bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, 16000, Endian.little);
    header.setUint32(28, 32000, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    bytes.setRange(36, 40, ascii.encode('data'));
    header.setUint32(40, pcm.length, Endian.little);
    bytes.setRange(44, bytes.length, pcm);
    return bytes;
  }

  void _validateMiniMaxResponse(Map<String, dynamic>? data) {
    if (data == null) {
      throw Exception('Empty response from TTS API');
    }

    final baseResp = data['base_resp'];
    if (baseResp is! Map<String, dynamic>) return;

    final statusCode = baseResp['status_code'];
    if (statusCode == null || statusCode == 0 || statusCode == '0') return;

    final statusMsg =
        baseResp['status_msg']?.toString() ?? 'MiniMax TTS request failed';
    if (statusCode == 1004 || statusCode == '1004') {
      throw Exception('MiniMax TTS 鉴权失败，请检查 MINIMAX_KEY 是否为有效 API Secret Key');
    }
    throw Exception('MiniMax TTS 错误 ($statusCode): $statusMsg');
  }

  List<int> _decodeHexAudio(String encodedAudio) {
    final normalized = encodedAudio.trim();
    if (normalized.isEmpty) return const [];
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(normalized)) {
      return base64Decode(normalized);
    }
    if (normalized.length.isOdd) {
      throw const FormatException('Invalid audio hex');
    }
    final bytes = <int>[];
    for (var i = 0; i < normalized.length - 1; i += 2) {
      bytes.add(int.parse(normalized.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  /// Stop current playback and clean up temp files.
  Future<void> stop() async {
    _generation++;
    _cancelToken?.cancel();
    _cancelToken = null;
    final player = _player;
    _player = null;
    _cleanupFile();
    await AvatarAudioBridge.stop();
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {}
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  /// Delete the last temp audio file.
  void _cleanupFile() {
    if (_lastFilePath != null) {
      try {
        File(_lastFilePath!).deleteSync();
      } catch (_) {}
      _lastFilePath = null;
    }
  }

  /// Release all resources.
  void dispose() {
    stop();
  }
}
