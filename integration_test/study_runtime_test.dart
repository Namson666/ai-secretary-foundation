import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai_secretary/features/study_runtime/study_avatar.dart';
import 'package:ai_secretary/features/study/application/study_tools.dart';
import 'package:ai_secretary/features/study/data/sqlite_study_repository.dart';
import 'package:ai_secretary/features/study/data/fsrs_scheduler.dart';
import 'package:ai_secretary/features/study/domain/study_models.dart';
import 'package:ai_secretary/features/study_runtime/study_conversation_runtime.dart';
import 'package:ai_secretary/services/avatar_audio_bridge.dart';
import 'package:ai_secretary/features/study_runtime/study_cloud_asr.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ai_secretary/features/study/presentation/coach_page.dart';
import 'package:ai_secretary/features/study/application/study_runtime_provider.dart';
import 'package:ai_secretary/features/study_runtime/study_voice_start_detector.dart';

/// Real native/provider probe. Only this test synthesizes fixed test speech and
/// injects PCM into ASR; production microphone capture has no injection mode.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Uint8List? nativeProbePcm;

  testWidgets('bundled DUIX ready, actual cloud TTS/ASR and mic cancellation', (
    tester,
  ) async {
    var ready = false;
    String? initError;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StudyAvatar(
            onReady: () {
              ready = true;
            },
            onError: (error) {
              initError = error;
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final coldWait = Stopwatch()..start();
    while (!ready && initError == null && coldWait.elapsed.inSeconds < 200) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
    }
    expect(initError, isNull);
    expect(ready, true);
    debugPrint(
      'STUDY_NATIVE_READY lifecycle=${WidgetsBinding.instance.lifecycleState}',
    );
    // The native window is already resumed. Drain the scheduled ready callback
    // frame before requesting playback from its attached avatar.
    await tester.pump();

    final pcm = await tester.runAsync(() async {
      const channel = MethodChannel('com.namson.ai_secretary/config');
      final key = await channel.invokeMethod<String>('getApiKey', {
        'key': 'minimax',
      });
      expect(key?.isNotEmpty, true);
      final response =
          await Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 40),
            ),
          ).post<Map<String, dynamic>>(
            'https://api.minimax.cn/v1/t2a_v2',
            options: Options(headers: {'Authorization': 'Bearer $key'}),
            data: {
              'model': 'speech-2.8-turbo',
              'text': 'Hello. I am learning English today.',
              'stream': false,
              'output_format': 'hex',
              'voice_setting': {
                'voice_id': 'female-tianmei',
                'speed': 1.0,
                'vol': 1,
                'pitch': 0,
              },
              'audio_setting': {
                'sample_rate': 16000,
                'format': 'pcm',
                'channel': 1,
              },
            },
          );
      final body = response.data!;
      expect((body['base_resp'] as Map)['status_code'], 0);
      final hex = (body['data'] as Map)['audio'] as String;
      final audio = Uint8List(hex.length ~/ 2);
      for (var i = 0; i < audio.length; i++) {
        audio[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }
      expect(audio.length, greaterThan(16000));
      return audio;
    });
    expect(pcm, isNotNull);
    nativeProbePcm = pcm;
    debugPrint(
      'STUDY_NATIVE_PLAY lifecycle=${WidgetsBinding.instance.lifecycleState} bytes=${pcm?.length}',
    );
    final played = await tester.runAsync(
      () => AvatarAudioBridge.play(pcm!).timeout(const Duration(seconds: 35)),
    );
    expect(played, true);

    // Feed the real synthesized PCM through the production continuous VAD path.
    // Only this integration test substitutes the microphone stream source.
    final injected = _FixedPcmRecorder();
    final asr = StudyCloudAsr(recorderFactory: () => injected);
    final recognized = Completer<String>();
    final gate = StudyVoiceStartDetector();
    String focus = 'A';
    String? captured;
    final transcript = await tester.runAsync(() async {
      asr.onFailure = () {
        if (!recognized.isCompleted) {
          recognized.completeError(StateError('Cloud ASR failed'));
        }
      };
      await asr.startConversation(
        onPartial: (_) {},
        onSpeechStart: () {},
        onPcm: (chunk) {
          if (gate.add(chunk)) {
            captured = focus;
            focus = 'B';
          }
        },
        onUtterance: (text) {
          if (!recognized.isCompleted) recognized.complete(text);
        },
      );
      final audio = pcm!;
      for (var offset = 0; offset < audio.length; offset += 3200) {
        injected.frames.add(
          Uint8List.sublistView(
            audio,
            offset,
            (offset + 3200).clamp(0, audio.length),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      for (var i = 0; i < 9; i++) {
        if (injected.frames.isClosed) break;
        injected.frames.add(Uint8List(3200));
      }
      try {
        return await recognized.future.timeout(const Duration(seconds: 50));
      } finally {
        await asr.cancel();
      }
    });
    expect(captured, 'A');
    expect(focus, 'B');
    asr.dispose();
    expect(transcript, isNotEmpty);
    expect(transcript!.toLowerCase(), contains('english'));
    // Fixed synthetic speech verifies protocol/model processing, not a human mic.
    debugPrint(
      'STUDY_NATIVE_PROBE: DUIX ready / TTS PCM played / ASR=$transcript',
    );

    final capture = StudyCloudAsr();
    final runtime = StudyConversationRuntime(asr: capture);
    await tester.runAsync(runtime.startHold);
    expect(runtime.error, isNull);
    expect(await tester.runAsync(() => capture.isCapturing), true);
    await tester.runAsync(runtime.cancelHold);
    expect(await tester.runAsync(() => capture.isCapturing), false);
    expect(runtime.messages, isEmpty);
    await tester.runAsync(runtime.close);
    runtime.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  testWidgets(
    'actual MiniMax add then next-turn undo with real native SQLite receipts',
    (tester) async {
      final catalog = StudyCatalog.fromJson(
        jsonDecode(await rootBundle.loadString('assets/study/vocabulary.json'))
            as Map<String, dynamic>,
      );
      final temp = await getTemporaryDirectory();
      final path = '${temp.path}/study_protocol_probe.sqlite';
      final repository = await SqliteStudyRepository.open(
        catalog,
        Fsrs6Scheduler(),
        databasePath: path,
      );
      final gateway = StudyTools(repository, catalog);
      final allowed = StudyTools.specifications
          .where(
            (tool) => {
              'study_review_point_add',
              'study_review_point_undo',
            }.contains((tool['function'] as Map)['name']),
          )
          .toList();
      final runtime = StudyConversationRuntime(
        captureContext: () => const StudyInputContext(
          focusId: 'resilient',
          systemPrompt:
              '你是学习助手。请通过工具执行用户明确指令，只依据工具返回的真实回执回复。加入发音复习用study_review_point_add，撤销刚才用study_review_point_undo，本轮可从前一轮工具回执读取operation_id。',
        ),
        tools: allowed,
        onTool: (name, args, captured) => gateway.invoke(
          name,
          args,
          StudyToolContext(
            commandId: captured.commandId!,
            userText: captured.finalText!,
            focusId: captured.focusId,
            isCurrent: () => captured.isCurrent,
          ),
        ),
      );
      await runtime.setSpeaker(false);
      try {
        await tester.runAsync(
          () => runtime.sendText('请把 resilient 加入发音复习，只保存这一条。'),
        );
        expect(runtime.error, isNull);
        expect(
          runtime.toolReceipts.any((r) => r['status'] == 'committed'),
          true,
        );
        final added = (await repository.load()).reviews
            .where(
              (r) =>
                  r.wordId == 'resilient' &&
                  r.skill == StudySkill.pronunciation &&
                  r.status == 'pending',
            )
            .toList();
        expect(added, isNotEmpty);
        await tester.runAsync(() => runtime.sendText('撤销刚才加入的发音复习。'));
        expect(runtime.error, isNull);
        expect(runtime.actualModel, 'MiniMax-M3.1-Flash-Preview');
        debugPrint(
          'STUDY_PROVIDER_MODEL: model=${runtime.actualModel} usage=${runtime.lastUsage}',
        );
        final rows = await repository.database.query(
          'contributions',
          where: 'point_id=?',
          whereArgs: [added.last.id],
        );
        expect(rows.where((r) => r['active'] == 1), isEmpty);
        expect(runtime.toolReceipts.length, greaterThanOrEqualTo(2));
        debugPrint(
          'STUDY_PROVIDER_PROBE: actual MiniMax tool add -> next turn undo -> native SQLite inactive contribution',
        );
      } finally {
        await runtime.close();
        runtime.dispose();
        await repository.close();
        for (final suffix in ['', '-wal', '-shm']) {
          final file = File('$path$suffix');
          if (await file.exists()) await file.delete();
        }
      }
    },
  );
  testWidgets(
    'native coach full/shrink preserves one avatar, call and PCM playback',
    (tester) async {
      final capture = StudyCloudAsr();
      final runtime = StudyConversationRuntime(asr: capture);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [studyRuntimeProvider.overrideWithValue(runtime)],
          child: const MaterialApp(
            home: Scaffold(body: StudyCoachPage(active: true)),
          ),
        ),
      );
      await tester.pump();
      for (
        var i = 0;
        i < 800 && find.text('正在载入数字人…').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump();
      }
      expect(find.text('正在载入数字人…'), findsNothing);
      expect(find.textContaining('文字与普通语音仍可用'), findsNothing);
      final avatarState = tester.state(find.byType(StudyAvatar));
      await tester.tap(find.text('实时通话'));
      await tester.pump();
      await tester.tap(find.byTooltip('开始实时语音通话'));
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        if (await tester.runAsync(() => capture.isCapturing) == true) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
      }
      expect(runtime.callActive, true);
      expect(runtime.error, isNull);
      await tester.runAsync(() => runtime.setMuted(true));
      await tester.pump();
      expect(await tester.runAsync(() => capture.isCapturing), false);
      debugPrint('STUDY_COACH_NATIVE: begin resize while native PCM plays');
      expect(nativeProbePcm, isNotNull);
      final playback = AvatarAudioBridge.play(nativeProbePcm!);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.tap(find.byTooltip('数字人全屏'));
      await tester.pump();
      expect(find.byType(StudyAvatar), findsOneWidget);
      expect(tester.state(find.byType(StudyAvatar)), same(avatarState));
      expect(runtime.callActive, true);
      expect(runtime.muted, true);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.tap(find.byTooltip('收起全屏'));
      await tester.pump();
      expect(tester.state(find.byType(StudyAvatar)), same(avatarState));
      expect(runtime.callActive, true);
      expect(runtime.muted, true);
      expect(
        await tester.runAsync(
          () => playback.timeout(const Duration(seconds: 35)),
        ),
        true,
      );
      debugPrint(
        'STUDY_COACH_NATIVE: full/shrink same avatar / PCM complete / call kept',
      );
      await tester.tap(find.byTooltip('结束'));
      await tester.pump();
      await tester.runAsync(runtime.endCall);
      expect(runtime.callActive, false);
      expect(await tester.runAsync(() => capture.isCapturing), false);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(runtime.close);
      runtime.dispose();
    },
  );
}

// Fixed speech source is confined to the integration test, never production APK.
class _FixedPcmRecorder extends AudioRecorder {
  final frames = StreamController<Uint8List>(sync: true);
  bool recording = false;
  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    recording = true;
    return frames.stream;
  }

  @override
  Future<bool> isRecording() async => recording;
  @override
  Future<String?> stop() async {
    recording = false;
    await frames.close();
    return null;
  }
}
