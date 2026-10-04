import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_secretary/core/database/database_helper.dart';
import 'package:ai_secretary/services/avatar_audio_bridge.dart';
import 'package:ai_secretary/services/tts_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class PcmAdapter implements HttpClientAdapter {
  RequestOptions? request;
  Completer<void>? hold;
  final entered = Completer<void>();
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    entered.complete();
    if (hold != null) await hold!.future;
    return ResponseBody.fromString(
      jsonEncode({
        'base_resp': {'status_code': 0},
        'data': {'audio': '000001000000ffff'},
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const config = MethodChannel('com.namson.ai_secretary/config');
  const avatar = MethodChannel('avatar-test');
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await DatabaseHelper.instance.database;
  });
  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(config, (call) async => 'test-only-key');
    messenger.setMockMethodCallHandler(avatar, (call) async {
      calls.add(call);
      return call.method == 'playPcm' ? true : null;
    });
    AvatarAudioBridge.attach(avatar);
  });
  tearDown(() {
    AvatarAudioBridge.detach(avatar);
    messenger.setMockMethodCallHandler(config, null);
    messenger.setMockMethodCallHandler(avatar, null);
  });
  test(
    'PCM request goes to the ready avatar once, without a second player',
    () async {
      final adapter = PcmAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final tts = TtsService(dio: dio);
      await tts.speak('你好');
      final body = adapter.request!.data as Map;
      expect(body['audio_setting'], {
        'sample_rate': 16000,
        'format': 'pcm',
        'channel': 1,
      });
      expect((body['voice_setting'] as Map)['voice_id'], 'female-tianmei');
      final sent = calls.where((call) => call.method == 'playPcm').single;
      expect((sent.arguments as Map)['pcm'], [0, 0, 1, 0, 0, 0, 255, 255]);
      await tts.stop();
    },
  );
  test('selected MiniMax voice is sent with the TTS request', () async {
    final adapter = PcmAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final tts = TtsService(dio: dio, voiceId: () => 'female-yujie');
    await tts.speak('你好');
    expect(
      ((adapter.request!.data as Map)['voice_setting'] as Map)['voice_id'],
      'female-yujie',
    );
    await tts.stop();
  });
  test('selected Turbo model is sent with the TTS request', () async {
    final adapter = PcmAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final tts = TtsService(dio: dio, model: () => 'speech-2.8-turbo');
    await tts.speak('你好');
    expect((adapter.request!.data as Map)['model'], 'speech-2.8-turbo');
    await tts.stop();
  });
  test('selected speech speed is sent with the TTS request', () async {
    final adapter = PcmAdapter();
    final tts = TtsService(
      dio: Dio()..httpClientAdapter = adapter,
      speed: () => 0.85,
    );
    await tts.speak('你好');
    expect(
      ((adapter.request!.data as Map)['voice_setting'] as Map)['speed'],
      0.85,
    );
    await tts.stop();
  });
  test('explicit emotion is sent only when supported', () async {
    final adapter = PcmAdapter();
    final tts = TtsService(dio: Dio()..httpClientAdapter = adapter);
    await tts.speak('太好了！', emotion: 'happy');
    expect(
      ((adapter.request!.data as Map)['voice_setting'] as Map)['emotion'],
      'happy',
    );
    await tts.stop();
    final plainAdapter = PcmAdapter();
    final plainTts = TtsService(dio: Dio()..httpClientAdapter = plainAdapter);
    await plainTts.speak('普通回答', emotion: 'invalid');
    expect(
      ((plainAdapter.request!.data as Map)['voice_setting'] as Map).containsKey(
        'emotion',
      ),
      isFalse,
    );
    await plainTts.stop();
  });
  test('stopped HTTP request never reaches avatar playback', () async {
    final adapter = PcmAdapter()..hold = Completer<void>();
    final dio = Dio()..httpClientAdapter = adapter;
    final tts = TtsService(dio: dio);
    final speaking = tts.speak('不要播报');
    await adapter.entered.future;
    await tts.stop();
    adapter.hold!.complete();
    await speaking;
    expect(calls.where((call) => call.method == 'playPcm'), isEmpty);
  });
  test('WAV fallback has mono 16kHz 16bit header and exact PCM', () {
    final pcm = Uint8List.fromList([0, 0, 255, 127]);
    final wav = TtsService.pcmToWav(pcm);
    final header = ByteData.sublistView(wav);
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint16(22, Endian.little), 1);
    expect(header.getUint16(34, Endian.little), 16);
    expect(wav.sublist(44), pcm);
    expect(() => TtsService.pcmToWav(Uint8List(3)), throwsFormatException);
  });
  test(
    'native playback errors propagate, not silently fall back to voice only',
    () async {
      messenger.setMockMethodCallHandler(avatar, (call) async {
        if (call.method == 'playPcm') {
          throw PlatformException(code: 'audio_error');
        }
        return null;
      });
      await expectLater(
        AvatarAudioBridge.play(Uint8List(4)),
        throwsA(isA<PlatformException>()),
      );
    },
  );
  test(
    'late failure from a detached avatar cannot stop the new avatar',
    () async {
      const nextAvatar = MethodChannel('avatar-next-test');
      final oldPlay = Completer<bool>();
      final entered = Completer<void>();
      final oldStops = <MethodCall>[];
      final nextCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(avatar, (call) async {
        if (call.method == 'playPcm') {
          entered.complete();
          return oldPlay.future;
        }
        oldStops.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(nextAvatar, (call) async {
        nextCalls.add(call);
        return call.method == 'playPcm' ? true : null;
      });
      addTearDown(() {
        AvatarAudioBridge.detach(nextAvatar);
        messenger.setMockMethodCallHandler(nextAvatar, null);
      });
      final playing = AvatarAudioBridge.play(Uint8List(4));
      final failure = expectLater(playing, throwsA(isA<PlatformException>()));
      await entered.future;
      AvatarAudioBridge.detach(avatar);
      AvatarAudioBridge.attach(nextAvatar);
      expect(await AvatarAudioBridge.play(Uint8List(4)), isTrue);
      oldPlay.completeError(PlatformException(code: 'late_audio_error'));
      await failure;
      expect(nextCalls.map((call) => call.method), ['playPcm']);
      expect(oldStops.map((call) => call.method), ['stopAudio']);
    },
  );
}
